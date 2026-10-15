//! Legacy update checker: a background GitHub releases probe (throttled
//! through `%LOCALAPPDATA%\ghostty\update_check_at`) that shows a tray
//! balloon linking to the releases page when a newer version exists.
//!
//! Moved verbatim from App.zig in W0-A1 (ARCHITECTURE.md ADR-1.8). W5b's
//! `updater` WP replaces it (correct repo URL, ADR-14.6).

const std = @import("std");
const Allocator = std.mem.Allocator;

const App = @import("../../App.zig");
const build_config = @import("../../../../build_config.zig");
const tasks = @import("../../app/tasks.zig");
const w32 = @import("../../platform/win32.zig");

const log = std.log.scoped(.win32);

/// GitHub releases API URL for this fork.
const UPDATE_URL = "https://api.github.com/repos/InsipidPoint/ghostty-windows/releases/latest";

/// User-facing GitHub releases page that the update balloon links to.
const RELEASES_URL = "https://github.com/InsipidPoint/ghostty-windows/releases/latest";

/// Tray icon ID of the update balloon. Distinct from the desktop
/// notification uIDs (100..107) so the two kinds of balloon can coexist
/// without one's auto-cleanup removing the other's icon. (Its cleanup
/// timer is an app.timers timer: App.update_balloon_timer.)
pub const NOTIF_UPDATE_UID: u32 = 2;

/// Hands the newer version string found by the update thread to the UI
/// thread (ownership of `version` transfers with the task).
const UpdateTask = struct {
    task: tasks.Task = .{ .run = run, .destroy = destroy },
    alloc: Allocator,
    version: []u8,

    fn run(app: *App, task: *tasks.Task) void {
        const self: *UpdateTask = @fieldParentPtr("task", task);
        showUpdateNotification(app, self.version);
    }

    fn destroy(task: *tasks.Task) void {
        const self: *UpdateTask = @fieldParentPtr("task", task);
        self.alloc.free(self.version);
        self.alloc.destroy(self);
    }
};

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

    // Allocate a heap copy and hand ownership to the UI thread through an
    // app.tasks task. This avoids a static-buffer race between this worker
    // thread writing the version and the UI thread reading it.
    const alloc = app.core_app.alloc;
    const owned = alloc.dupe(u8, latest_ver) catch {
        log.warn("oom allocating update version", .{});
        return;
    };
    const task = alloc.create(UpdateTask) catch {
        alloc.free(owned);
        return;
    };
    task.* = .{ .alloc = alloc, .version = owned };
    app.tasks.post(&task.task);
}

/// Show a notification balloon that an update is available. `ver` is
/// owned by the caller (the UpdateTask frees it).
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
    // (Re)start the 10 s icon cleanup (a re-shown balloon restarts it).
    self.timers.stop(self.update_balloon_timer);
    self.update_balloon_timer = self.timers.start(10000, .{}, 0, onBalloonTimer);
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

/// app.timers callback: the update balloon's 10 s cleanup elapsed; remove
/// its tray icon. (Moved from App.msgWndProc.)
fn onBalloonTimer(app: *App, ctx: usize) void {
    _ = ctx;
    app.update_balloon_timer = 0;
    const hwnd = app.msg_hwnd orelse return;
    var nid: w32.NOTIFYICONDATAW = std.mem.zeroes(w32.NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(w32.NOTIFYICONDATAW);
    nid.hWnd = hwnd;
    nid.uID = NOTIF_UPDATE_UID;
    _ = w32.Shell_NotifyIconW(w32.NIM_DELETE, &nid);
}
