//! Legacy update checker: a background GitHub releases probe (throttled
//! through `%LOCALAPPDATA%\ghostty\update_check_at`) that shows a tray
//! balloon linking to the releases page when a newer version exists.
//!
//! Moved verbatim from App.zig in W0-A1 (ARCHITECTURE.md ADR-1.8). W5b's
//! `updater` WP replaces it (correct repo URL, ADR-14.6).

const std = @import("std");

const App = @import("../../App.zig");
const build_config = @import("../../../../build_config.zig");
const w32 = @import("../../platform/win32.zig");

const log = std.log.scoped(.win32);

/// GitHub releases API URL for this fork.
const UPDATE_URL = "https://api.github.com/repos/InsipidPoint/ghostty-windows/releases/latest";

/// Custom message posted from the update thread to the message loop.
pub const WM_APP_UPDATE_AVAILABLE: u32 = w32.WM_APP + 2;

/// User-facing GitHub releases page that the update balloon links to.
const RELEASES_URL = "https://github.com/InsipidPoint/ghostty-windows/releases/latest";

/// Tray icon and timer IDs for notifications. Distinct IDs mean the
/// desktop and update balloons can coexist without one's auto-cleanup
/// removing the other's icon. Timer IDs share the msg_hwnd WM_TIMER
/// namespace with QUIT_TIMER_ID=1 and QuickTerminal.ANIM_TIMER_ID=3 and
/// must stay unique across all of them (the update timer was 3, which
/// the anim-timer check shadowed whenever a quick terminal existed,
/// leaving the update tray icon undeleted).
pub const NOTIF_UPDATE_UID: u32 = 2;
pub const NOTIF_UPDATE_TIMER_ID: usize = 4;

/// Minimum interval between update checks, in seconds. The check
/// timestamp is persisted in %LOCALAPPDATA%/ghostty/update_check_at.
const UPDATE_CHECK_INTERVAL_SECS: i64 = 60 * 60; // 1 hour

/// Start a background thread to check for updates. Skips the actual
/// fetch if we checked within the last UPDATE_CHECK_INTERVAL_SECS.
/// Manual `.check_for_updates` actions force-refresh by setting
/// `force=true`.
pub fn startUpdateCheck(self: *App) void {
    if (!shouldRunUpdateCheck(self)) {
        log.debug("skipping update check (last run within {d}s)", .{UPDATE_CHECK_INTERVAL_SECS});
        return;
    }
    _ = std.Thread.spawn(.{}, updateCheckThread, .{self}) catch |err| {
        log.warn("failed to start update check thread: {}", .{err});
    };
}

/// Read the persisted "last checked at" timestamp; return true if
/// it's missing/stale. Updates the file with the current timestamp on
/// the way out so a successful return throttles the next call.
fn shouldRunUpdateCheck(self: *App) bool {
    const alloc = self.core_app.alloc;
    const dir = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch return true;
    defer alloc.free(dir);
    const path = std.fs.path.join(alloc, &.{ dir, "ghostty", "update_check_at" }) catch return true;
    defer alloc.free(path);

    const now = std.time.timestamp();
    if (std.fs.cwd().openFile(path, .{})) |f| {
        defer f.close();
        var buf: [32]u8 = undefined;
        const n = f.readAll(&buf) catch 0;
        const text = std.mem.trim(u8, buf[0..n], " \t\r\n");
        if (std.fmt.parseInt(i64, text, 10)) |last| {
            if (now - last < UPDATE_CHECK_INTERVAL_SECS) return false;
        } else |_| {}
    } else |_| {}

    // Write (or create) the file with the current timestamp.
    if (std.fs.cwd().makePath(std.fs.path.dirname(path) orelse return true)) |_| {} else |_| {}
    if (std.fs.cwd().createFile(path, .{ .truncate = true })) |f| {
        defer f.close();
        var ts_buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&ts_buf, "{d}", .{now}) catch return true;
        f.writeAll(s) catch {};
    } else |_| {}
    return true;
}

/// Background thread: fetch latest release tag from GitHub, compare
/// with current version, post a message if newer.
fn updateCheckThread(app: *App) void {
    const result = fetchLatestVersion() catch |err| {
        log.debug("update check failed: {}", .{err});
        return;
    };

    const latest = result.tag;
    const latest_len = result.len;
    if (latest_len == 0) return;

    // Strip "win-v" or "v" prefix from tag
    const latest_start: usize = if (std.mem.startsWith(u8, latest[0..latest_len], "win-v"))
        5
    else if (latest[0] == 'v')
        1
    else
        0;
    const latest_ver = latest[latest_start..latest_len];

    // Compare against the binary's own version (set by build.zig from
    // either build.zig.zon or the win-v git tag at build time).
    const current_sv = build_config.version;
    const latest_sv = std.SemanticVersion.parse(latest_ver) catch {
        log.debug("failed to parse remote version: {s}", .{latest_ver});
        return;
    };

    // Only notify if the remote version is strictly newer
    if (latest_sv.order(current_sv) != .gt) {
        log.debug("up to date: current={d}.{d}.{d} latest={s}", .{
            current_sv.major, current_sv.minor, current_sv.patch, latest_ver,
        });
        return;
    }
    log.info("update available: current={d}.{d}.{d} latest={s}", .{
        current_sv.major, current_sv.minor, current_sv.patch, latest_ver,
    });

    const hwnd = app.msg_hwnd orelse return;

    // Allocate a heap copy and hand ownership to the message handler via
    // wparam/lparam. This avoids a static-buffer race between this worker
    // thread writing the version and the message thread reading it.
    const alloc = app.core_app.alloc;
    const owned = alloc.dupe(u8, latest_ver) catch {
        log.warn("oom allocating update version", .{});
        return;
    };
    const wparam: usize = @intFromPtr(owned.ptr);
    const lparam: isize = @intCast(owned.len);
    if (w32.PostMessageW(hwnd, WM_APP_UPDATE_AVAILABLE, wparam, lparam) == 0) {
        // PostMessage failed (e.g., HWND already destroyed). Free the
        // buffer here since the handler will never run.
        alloc.free(owned);
    }
}

/// Show a notification balloon that an update is available. The handler
/// owns `ver` (heap-allocated by updateCheckThread) and is responsible
/// for freeing it.
pub fn showUpdateNotification(self: *App, ver: []const u8) void {
    const hwnd = self.msg_hwnd orelse return;
    if (ver.len == 0) return;
    const ver_len = ver.len;

    var nid: w32.NOTIFYICONDATAW = std.mem.zeroes(w32.NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(w32.NOTIFYICONDATAW);
    nid.hWnd = hwnd;
    nid.uID = NOTIF_UPDATE_UID;
    // NIF_MESSAGE registers our callback so a click on the balloon
    // is delivered as WM_APP_TRAY → opens the GitHub releases page.
    nid.uFlags = w32.NIF_INFO | w32.NIF_ICON | w32.NIF_TIP | w32.NIF_MESSAGE;
    nid.uCallbackMessage = App.WM_APP_TRAY;
    nid.hIcon = w32.LoadIconW(self.hinstance, w32.IDI_GHOSTTY) orelse w32.LoadIconW(null, w32.IDI_APPLICATION);
    nid.dwInfoFlags = w32.NIIF_INFO;
    nid.uVersion_or_uTimeout = 10000;

    // Title
    const title = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty Update Available");
    @memcpy(nid.szInfoTitle[0..title.len], title);
    nid.szInfoTitle[title.len] = 0;

    // Body: "Version X.Y.Z is available. Visit GitHub to download."
    var body_utf8: [256]u8 = undefined;
    const body_len = std.fmt.bufPrint(&body_utf8, "Version {s} is available.\nVisit GitHub releases to download.", .{ver[0..ver_len]}) catch return;
    var body_utf16: [256]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&body_utf16, body_len) catch 0;
    @memcpy(nid.szInfo[0..wlen], body_utf16[0..wlen]);
    nid.szInfo[wlen] = 0;

    const tip = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");
    @memcpy(nid.szTip[0..tip.len], tip);
    nid.szTip[tip.len] = 0;

    _ = w32.Shell_NotifyIconW(w32.NIM_ADD, &nid);
    _ = w32.Shell_NotifyIconW(w32.NIM_MODIFY, &nid);
    _ = w32.SetTimer(hwnd, NOTIF_UPDATE_TIMER_ID, 10000, null);
}

const VersionResult = struct { tag: [128]u8, len: usize };

/// Fetch the latest release tag from GitHub. Returns the tag string.
fn fetchLatestVersion() !VersionResult {
    const agent = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty-UpdateCheck/1.0");
    const inet = w32.InternetOpenW(agent, w32.INTERNET_OPEN_TYPE_PRECONFIG, null, null, 0) orelse
        return error.InternetOpenFailed;
    defer _ = w32.InternetCloseHandle(inet);

    // Convert URL to UTF-16
    var url_buf: [256]u16 = undefined;
    const url_len = std.unicode.utf8ToUtf16Le(&url_buf, UPDATE_URL) catch return error.UrlTooLong;
    url_buf[url_len] = 0;

    const flags = w32.INTERNET_FLAG_SECURE | w32.INTERNET_FLAG_NO_CACHE_WRITE | w32.INTERNET_FLAG_RELOAD;
    const conn = w32.InternetOpenUrlW(inet, @ptrCast(&url_buf), null, 0, flags, 0) orelse
        return error.InternetOpenUrlFailed;
    defer _ = w32.InternetCloseHandle(conn);

    // Read response (we only need the first ~4KB for tag_name)
    var response: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < response.len) {
        var bytes_read: u32 = 0;
        if (w32.InternetReadFile(conn, response[total..].ptr, @intCast(response.len - total), &bytes_read) == 0) {
            return error.ReadFailed;
        }
        if (bytes_read == 0) break;
        total += bytes_read;
    }

    // Find "tag_name" in JSON response (simple string search, no JSON parser needed)
    const json = response[0..total];
    const needle = "\"tag_name\":\"";
    const start = std.mem.indexOf(u8, json, needle) orelse return error.TagNotFound;
    const tag_start = start + needle.len;
    const tag_end = std.mem.indexOfPos(u8, json, tag_start, "\"") orelse return error.TagNotFound;
    const tag = json[tag_start..tag_end];

    var result: VersionResult = .{ .tag = undefined, .len = tag.len };
    if (tag.len > 128) return error.TagTooLong;
    @memcpy(result.tag[0..tag.len], tag);
    return result;
}

/// UI-thread handler for WM_APP_UPDATE_AVAILABLE (moved from
/// App.msgWndProc): wparam = heap pointer to the version string, lparam =
/// length. We own the buffer and must free it after use.
pub fn onUpdateAvailable(app: *App, wparam: usize, lparam: isize) void {
    if (wparam != 0 and lparam > 0) {
        const ptr: [*]u8 = @ptrFromInt(wparam);
        const len: usize = @intCast(lparam);
        const ver = ptr[0..len];
        defer app.core_app.alloc.free(ver);
        showUpdateNotification(app, ver);
    }
}

/// A click on the update balloon (WM_APP_TRAY with NOTIF_UPDATE_UID)
/// opens the GitHub releases page. (Moved from App.msgWndProc.)
pub fn openReleasesPage() void {
    var url_buf: [256]u16 = undefined;
    const url_len = std.unicode.utf8ToUtf16Le(&url_buf, RELEASES_URL) catch return;
    url_buf[url_len] = 0;
    _ = w32.ShellExecuteW(
        null,
        std.unicode.utf8ToUtf16LeStringLiteral("open"),
        @ptrCast(&url_buf),
        null,
        null,
        w32.SW_SHOW,
    );
}

/// NOTIF_UPDATE_TIMER_ID fired on msg_hwnd: remove the update balloon's
/// tray icon. (Moved from App.msgWndProc.)
pub fn onBalloonTimer(hwnd: w32.HWND) void {
    _ = w32.KillTimer(hwnd, NOTIF_UPDATE_TIMER_ID);
    var nid: w32.NOTIFYICONDATAW = std.mem.zeroes(w32.NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(w32.NOTIFYICONDATAW);
    nid.hWnd = hwnd;
    nid.uID = NOTIF_UPDATE_UID;
    _ = w32.Shell_NotifyIconW(w32.NIM_DELETE, &nid);
}
