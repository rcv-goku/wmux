//! Legacy notification ring: the sidebar notification log (`NotifRing`
//! of `NotifEntry`), unread accounting and the taskbar overlay badge, the
//! OSC 9 attention sentinel, desktop balloons (`Shell_NotifyIconW`) with
//! their click targets, and jump-to-surface.
//!
//! Moved verbatim from App.zig in W0-A1 (ARCHITECTURE.md ADR-1.8). The
//! state still lives on App (`notif_log`, `desktop_notifs`, `taskbar_list`);
//! W0-A3 moves it into the feature's ext state and W2-5 replaces this file
//! with the notification store and delivery pipeline (ADR-7). Other code
//! reaches it through `api.zig`.

const std = @import("std");

const apprt = @import("../../../../apprt.zig");
const App = @import("../../App.zig");
const Surface = @import("../../Surface.zig");
const Window = @import("../../Window.zig");
const hooks = @import("../../app/hooks.zig");
const taskbar = @import("../../platform/taskbar.zig");
const w32 = @import("../../platform/win32.zig");

const log = std.log.scoped(.win32);

/// Desktop notifications rotate through a small range of slots so that
/// several balloons can be in flight at once, each with its own tray
/// uID, cleanup timer, and recorded click target. Slot `i` uses uID
/// NOTIF_DESKTOP_UID_BASE+i and the app.timers timer in
/// App.desktop_notif_timers[i].
pub const NOTIF_DESKTOP_SLOTS: usize = 8;
pub const NOTIF_DESKTOP_UID_BASE: u32 = 100;

/// Click target recorded for an in-flight desktop notification. The
/// pointers may dangle by the time the balloon is clicked (tab or
/// window closed since), so they are compared by address against the
/// live window/tab lists before being dereferenced.
pub const DesktopNotif = struct {
    window: *Window,
    surface: *Surface,
};

/// Capacity of the sidebar notification log ring buffer.
pub const NOTIF_LOG_CAP: usize = 64;

/// One sidebar notification log entry. Title/body are stored inline
/// (UTF-16, truncated) so painting never dereferences the window or
/// surface pointers; those are only used to jump and are validated by
/// address first (jumpToSurface), like DesktopNotif.
pub const NotifEntry = struct {
    pub const Kind = enum { osc, bell, exited };

    kind: Kind,
    window: *Window,
    surface: *Surface,
    title: [128]u16,
    title_len: usize,
    body: [128]u16,
    body_len: usize,
    /// Per-entry lifecycle: false = Unread (contributes to the badge and is
    /// a `+notify next` jump target), true = Read (the user viewed it, by
    /// opening the panel or jumping to it). Distinct from the ring's
    /// aggregate `unread` counter, which drives the bell badge: a freshly
    /// pushed entry is Unread; markRead/opening the panel marks all live
    /// entries Read; jumping to one marks just that one Read.
    read: bool = false,
};

/// Fixed-capacity ring of optional entries with newest-first display
/// indexing and an unread counter. Pure accounting (no Win32) so the
/// wrap/hole/unread rules are unit-testable; callers handle repaints.
pub fn NotifRing(comptime Entry: type, comptime cap: usize) type {
    return struct {
        const Self = @This();

        /// Slots, written round-robin at `next`. Holes (nulled slots)
        /// are skipped by count/at so display indices stay contiguous.
        slots: [cap]?Entry = @splat(null),

        /// Next slot to overwrite.
        next: usize = 0,

        /// Entries pushed since the last markRead. Counts pushes, not
        /// live slots, so it can exceed `cap` (the sidebar badge
        /// saturates its display at "9+" regardless).
        unread: usize = 0,

        pub fn push(self: *Self, entry: Entry) void {
            self.slots[self.next] = entry;
            self.next = (self.next + 1) % cap;
            self.unread += 1;
        }

        /// Reset the unread counter. Returns true when it was nonzero
        /// (the caller repaints only then).
        pub fn markRead(self: *Self) bool {
            if (self.unread == 0) return false;
            self.unread = 0;
            return true;
        }

        /// Drop every entry and the unread counter.
        pub fn clear(self: *Self) void {
            self.slots = @splat(null);
            self.next = 0;
            self.unread = 0;
        }

        /// Number of live entries.
        pub fn count(self: *const Self) usize {
            var n: usize = 0;
            for (self.slots) |slot| {
                if (slot != null) n += 1;
            }
            return n;
        }

        /// Count of live entries whose `read` field is false. Only valid
        /// when `Entry` has a `read: bool` field (the notification log);
        /// drives the taskbar unread-count badge. Pure so the read-flag
        /// accounting is unit-testable.
        pub fn unreadLive(self: *const Self) usize {
            var n: usize = 0;
            for (self.slots) |slot| {
                if (slot) |entry| {
                    if (!entry.read) n += 1;
                }
            }
            return n;
        }

        /// Display index (0 = newest) of the most-recent live entry whose
        /// `read` field is false, or null when every live entry is read.
        /// Walks newest-first using the same hole-skipping mapping as `at`.
        pub fn firstUnread(self: *const Self) ?usize {
            var display_idx: usize = 0;
            for (0..cap) |offset| {
                const idx = (self.next + cap - 1 - offset) % cap;
                if (self.slots[idx]) |entry| {
                    if (!entry.read) return display_idx;
                    display_idx += 1;
                }
            }
            return null;
        }

        /// Display index (0 = newest) of the **oldest** live entry whose
        /// `read` field is false, or null when every live entry is read.
        /// Walks newest-first, tracking the last seen unread.
        pub fn lastUnread(self: *const Self) ?usize {
            var display_idx: usize = 0;
            var result: ?usize = null;
            for (0..cap) |offset| {
                const idx = (self.next + cap - 1 - offset) % cap;
                if (self.slots[idx]) |entry| {
                    if (!entry.read) result = display_idx;
                    display_idx += 1;
                }
            }
            return result;
        }

        /// The display_idx-th newest live entry (0 = newest), or null
        /// past the end.
        pub fn at(self: *const Self, display_idx: usize) ?*const Entry {
            var seen: usize = 0;
            for (0..cap) |offset| {
                const idx = (self.next + cap - 1 - offset) % cap;
                if (self.slots[idx]) |*entry| {
                    if (seen == display_idx) return entry;
                    seen += 1;
                }
            }
            return null;
        }
    };
}

/// Show a Windows balloon notification via Shell_NotifyIconW.
/// Creates a temporary tray icon, shows the balloon, then removes
/// the icon after a short delay.
/// Sentinel an agent emits via OSC 9 to toggle this pane's attention
/// ring without a desktop balloon. We piggyback on OSC 9 (the desktop
/// notification channel, which already routes a pane→apprt message on
/// every platform) rather than adding a private OSC to the shared
/// terminal parser, keeping the feature contained to the Win32 apprt.
///
///   set:   printf '\033]9;@ghostty-attention:ring\033\\'
///   clear: printf '\033]9;@ghostty-attention:clear\033\\'
///
/// (`\033\\` is ST; BEL `\a` works too.) PowerShell:
///   $e=[char]27; Write-Host "$e]9;@ghostty-attention:ring$e\" -NoNewline
pub const ATTENTION_OSC_PREFIX = "@ghostty-attention:";

/// Parse an OSC 9 notification body for the attention sentinel. Returns
/// true ("ring"), false ("clear"), or null when the body is an ordinary
/// notification (the caller then shows a normal balloon). Pure so the
/// wire format is unit-testable. Surrounding ASCII whitespace is trimmed
/// so a shell that pads the sequence still matches.
pub fn parseAttentionOsc(body: []const u8) ?bool {
    const trimmed = std.mem.trim(u8, body, &std.ascii.whitespace);
    if (!std.mem.startsWith(u8, trimmed, ATTENTION_OSC_PREFIX)) return null;
    const verb = trimmed[ATTENTION_OSC_PREFIX.len..];
    if (std.mem.eql(u8, verb, "ring")) return true;
    if (std.mem.eql(u8, verb, "clear")) return false;
    return null;
}

/// Inputs to the smart desktop-toast suppression decision. Captured on the
/// UI thread immediately before the toast call so the decision is a pure
/// function of observable state (and thus unit-testable).
pub const ToastContext = struct {
    /// The Ghostty window owning the sending surface is the OS foreground
    /// window (GetForegroundWindow() == window.hwnd).
    window_foreground: bool,
    /// The sending surface's workspace is the active workspace in its
    /// window (the user is looking at that workspace's panes).
    workspace_active: bool,
    /// The notifications panel is open in the sending window (the user is
    /// actively watching the in-app notification log).
    panel_open: bool,
};

/// Decide whether to fire the Windows toast/balloon for a desktop
/// notification. The in-app attention ring + sidebar panel ALWAYS record
/// the event regardless; this governs only the OS-level interruption.
///
/// Suppress the toast only when the user is genuinely already looking at
/// the source: the window is in the foreground AND either the sending
/// workspace is the active one or the notifications panel is open. In every
/// other case (window backgrounded, or a different workspace is active and
/// the panel is closed) the toast fires so the user isn't left unaware.
///
/// Pure so the policy is unit-tested independent of any HWND/Win32 state.
pub fn shouldToast(ctx: ToastContext) bool {
    if (!ctx.window_foreground) return true;
    // Foregrounded: only suppress if the user is plausibly already watching
    // this notification's source.
    return !(ctx.workspace_active or ctx.panel_open);
}

pub fn showDesktopNotification(
    self: *App,
    target: apprt.Target,
    value: apprt.Action.Value(.desktop_notification),
) void {
    const hwnd = self.msg_hwnd orelse return;

    // Intercept the attention sentinel before doing any balloon work: an
    // agent's `OSC 9 ; @ghostty-attention:ring` sets/clears the ring on
    // its own pane and produces neither a balloon nor a log entry. Only a
    // surface target carries a pane to ring.
    if (parseAttentionOsc(value.body)) |on| {
        switch (target) {
            .app => {},
            .surface => |core_surface| {
                const rt = core_surface.rt_surface;
                rt.parent_window.setAttentionForSurface(rt, on);
            },
        }
        return;
    }

    // Convert title/body once (UTF-8 → UTF-16LE); reused by both the
    // in-app log entry and the balloon. Local buffers so the in-app path
    // works even when the balloon is suppressed.
    var title_buf: [64]u16 = undefined;
    var body_buf: [256]u16 = undefined;
    var title_len = std.unicode.utf8ToUtf16Le(&title_buf, value.title) catch 0;
    if (title_len >= title_buf.len) title_len = title_buf.len - 1;
    title_buf[title_len] = 0;
    var body_len = std.unicode.utf8ToUtf16Le(&body_buf, value.body) catch 0;
    if (body_len >= body_buf.len) body_len = body_buf.len - 1;
    body_buf[body_len] = 0;

    // The in-app side (attention ring + sidebar notification panel) ALWAYS
    // fires, regardless of the suppression decision below: a notification
    // is recorded and the pane is ringed even when we skip the OS toast.
    // Only a surface target carries a pane to ring / a window to address.
    const sender: ?DesktopNotif = switch (target) {
        .app => null,
        .surface => |core_surface| .{
            .window = core_surface.rt_surface.parent_window,
            .surface = core_surface.rt_surface,
        },
    };
    if (sender) |s| {
        // Ring the originating pane (the cmux-style attention ring). Skips
        // silently if the pane is the focused/visible one (you're already
        // looking at it) — setAttentionForSurface validates by address.
        s.window.setAttentionForSurface(s.surface, true);
        pushNotif(self, .osc, s.window, s.surface, title_buf[0..title_len], body_buf[0..body_len]);
    }

    // Smart suppression: skip the OS toast when the user is genuinely
    // already looking at the source. Decision captured from live UI state
    // here on the UI thread (see shouldToast). App targets (no window)
    // always toast.
    if (sender) |s| {
        const ctx: ToastContext = .{
            .window_foreground = if (s.window.hwnd) |wh| w32.GetForegroundWindow() == wh else false,
            .workspace_active = if (s.window.findLocOfSurface(s.surface)) |loc|
                s.window.workspaceIndex(loc.ws) == s.window.active_workspace
            else
                false,
            .panel_open = s.window.notif_panel_open,
        };
        if (!shouldToast(ctx)) {
            log.debug("suppressing desktop toast (user is looking at the source)", .{});
            // Keep the taskbar overlay in sync even when the toast is
            // suppressed (the badge reflects the in-app unread count).
            refreshTaskbarBadges(self);
            return;
        }
    }

    // Record which surface notified so a click on the balloon can jump
    // back to it. Slots rotate; if all are in flight the oldest balloon
    // is replaced (NIM_ADD fails silently, NIM_MODIFY updates in place,
    // and the slot's cleanup timer is restarted).
    const slot = self.desktop_notif_next;
    self.desktop_notif_next = (slot + 1) % NOTIF_DESKTOP_SLOTS;
    self.desktop_notifs[slot] = sender;

    var nid: w32.NOTIFYICONDATAW = std.mem.zeroes(w32.NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(w32.NOTIFYICONDATAW);
    nid.hWnd = hwnd;
    nid.uID = NOTIF_DESKTOP_UID_BASE + @as(u32, @intCast(slot));
    // NIF_MESSAGE registers our callback so a click on the balloon is
    // delivered as WM_APP_TRAY → jump to the notifying surface.
    nid.uFlags = w32.NIF_INFO | w32.NIF_ICON | w32.NIF_TIP | w32.NIF_MESSAGE;
    nid.uCallbackMessage = hooks.WM_APP_TRAY;
    nid.hIcon = w32.LoadIconW(self.hinstance, w32.IDI_GHOSTTY) orelse w32.LoadIconW(null, w32.IDI_APPLICATION);
    nid.dwInfoFlags = w32.NIIF_INFO;
    nid.uVersion_or_uTimeout = 5000; // 5 second timeout

    const ti_len = @min(title_len, nid.szInfoTitle.len - 1);
    @memcpy(nid.szInfoTitle[0..ti_len], title_buf[0..ti_len]);
    nid.szInfoTitle[ti_len] = 0;
    const bo_len = @min(body_len, nid.szInfo.len - 1);
    @memcpy(nid.szInfo[0..bo_len], body_buf[0..bo_len]);
    nid.szInfo[bo_len] = 0;

    // Tooltip
    const tip = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");
    @memcpy(nid.szTip[0..tip.len], tip);
    nid.szTip[tip.len] = 0;

    // Add the icon, show notification, then remove the icon.
    _ = w32.Shell_NotifyIconW(w32.NIM_ADD, &nid);
    _ = w32.Shell_NotifyIconW(w32.NIM_MODIFY, &nid);

    // Update the taskbar unread-count overlay to match the new entry.
    refreshTaskbarBadges(self);

    // Schedule icon removal via a per-slot app.timers timer (distinct
    // from the update notification's timer so the two don't trample each
    // other); reusing a slot restarts its timer.
    self.timers.stop(self.desktop_notif_timers[slot]);
    self.desktop_notif_timers[slot] = self.timers.start(6000, .{}, slot, onDesktopNotifTimer);
}

/// app.timers callback: desktop-balloon slot `slot`'s 6 s cleanup elapsed.
fn onDesktopNotifTimer(self: *App, slot: usize) void {
    self.desktop_notif_timers[slot] = 0;
    clearDesktopNotif(self, slot);
}

/// App hook for hooks.WM_APP_TRAY (wparam = icon uID, lparam = NIN_*
/// event): claims the desktop-notification uIDs; a balloon click jumps to
/// the surface that produced it. Other uIDs are left to their owners.
/// (Moved from App.msgWndProc.)
pub fn onTrayCallback(self: *App, wparam: usize, lparam: isize) ?isize {
    if (wparam < NOTIF_DESKTOP_UID_BASE or
        wparam >= NOTIF_DESKTOP_UID_BASE + NOTIF_DESKTOP_SLOTS) return null;
    const event: u32 = @intCast(lparam & 0xFFFF);
    if (event == w32.NIN_BALLOONUSERCLICK) {
        onDesktopNotifClick(self, wparam - NOTIF_DESKTOP_UID_BASE);
    }
    return 0;
}

/// A desktop-notification balloon was clicked: jump to the surface that
/// produced it, then tear down the balloon's icon, timer, and slot.
fn onDesktopNotifClick(self: *App, slot: usize) void {
    const notif = self.desktop_notifs[slot];
    clearDesktopNotif(self, slot);

    const target = notif orelse return;
    _ = jumpToSurface(self, target.window, target.surface);
}

/// Validate a captured (window, surface) pair by address against the
/// live window/tab lists, then raise the window, select the surface's
/// tab, and focus it. Returns false when either has closed since the
/// pointers were recorded. Shared by desktop-notification balloon
/// clicks and sidebar notification panel entries.
pub fn jumpToSurface(self: *App, window: *Window, surface: *Surface) bool {
    // Re-find both by address before dereferencing (mirrors
    // .present_terminal): the pointers may dangle.
    const win = for (self.windows.items) |w| {
        if (w == window) break w;
    } else return false;
    if (win.closing) return false;
    const loc = win.findLocOfSurface(surface) orelse return false;

    const win_hwnd = win.hwnd orelse return false;
    // Only un-minimize: SW_RESTORE on a *maximized* window un-maximizes it
    // to the restored rect, so a notification-jump click would shrink/resize
    // a maximized window. Gate on IsIconic so a maximized or normal window
    // keeps its size/maximized state untouched.
    if (w32.IsIconic(win_hwnd) != 0) _ = w32.ShowWindow(win_hwnd, w32.SW_RESTORE);
    // The click may land outside the target window (shell tray, another
    // window's sidebar), where Windows treats us as a background
    // process; a plain SetForegroundWindow would only flash the
    // taskbar button.
    App.forceForegroundWindow(win_hwnd);
    // Select the workspace containing the surface first (re-lays out for
    // its tab count), then the container and tab within it.
    win.selectWorkspace(win.workspaceIndex(loc.ws));
    loc.ws.focused_container = loc.container;
    if (loc.tab != loc.container.active_tab) win.selectTabIndex(loc.tab);
    if (surface.hwnd) |sh| _ = w32.SetFocus(sh);
    return true;
}

/// Append an entry to the sidebar notification log, bump the unread
/// badge, and repaint every sidebar. Title/body are UTF-16 and
/// truncated to the entry's inline buffers.
pub fn pushNotif(
    self: *App,
    kind: NotifEntry.Kind,
    window: *Window,
    surface: *Surface,
    title: []const u16,
    body: []const u16,
) void {
    var entry: NotifEntry = .{
        .kind = kind,
        .window = window,
        .surface = surface,
        .title = undefined,
        .title_len = @min(title.len, 128),
        .body = undefined,
        .body_len = @min(body.len, 128),
    };
    @memcpy(entry.title[0..entry.title_len], title[0..entry.title_len]);
    @memcpy(entry.body[0..entry.body_len], body[0..entry.body_len]);
    self.notif_log.push(entry);
    for (self.windows.items) |w| w.invalidateSidebar();
    // Received → Unread: the new entry bumps the taskbar overlay count.
    // (showDesktopNotification also refreshes after a balloon, but pushes
    // from the bell/exit paths land here only, so refresh unconditionally.)
    refreshTaskbarBadges(self);
}

/// Reset the unread badge and mark every live entry Read (the user opened
/// the notifications panel / clicked the bell — they have now "viewed" the
/// log). Repaints only when something actually changed. This is the
/// Unread→Read lifecycle transition for the whole log.
pub fn markNotifsRead(self: *App) void {
    var changed = self.notif_log.markRead();
    for (&self.notif_log.slots) |*slot| {
        if (slot.*) |*entry| {
            if (!entry.read) {
                entry.read = true;
                changed = true;
            }
        }
    }
    if (!changed) return;
    for (self.windows.items) |w| w.invalidateSidebar();
    // Unread → Read for the whole log: clear/lower the taskbar badge.
    refreshTaskbarBadges(self);
}

/// Count of live notification-log entries still marked Unread. This is the
/// number drawn on the taskbar overlay badge (cmux's dock-badge analog) and
/// is distinct from `notif_log.unread`, which counts *pushes* since the
/// last markRead and drives the sidebar bell badge. Counting live Unread
/// entries means the taskbar badge clears correctly once the panel is
/// opened (markNotifsRead flips every entry to Read) or each entry is
/// jumped to.
pub fn unreadNotifCount(self: *const App) usize {
    return self.notif_log.unreadLive();
}

/// Update every window's taskbar-button overlay to reflect the current
/// unread-notification count (0 clears the badge). Lazily creates the
/// process-wide ITaskbarList3 on first use; a creation failure (no COM)
/// makes this a silent no-op forever after. Called whenever the unread
/// count can change: a push, a markRead, a jump, or a clear.
pub fn refreshTaskbarBadges(self: *App) void {
    if (self.taskbar_list == null) {
        if (self.taskbar_tried) return;
        self.taskbar_tried = true;
        self.taskbar_list = taskbar.TaskbarList.create();
        if (self.taskbar_list == null) return;
    }
    const tl = &self.taskbar_list.?;
    const count = unreadNotifCount(self);
    for (self.windows.items) |w| {
        if (w.closing) continue;
        if (w.hwnd) |hwnd| tl.setOverlayCount(hwnd, count);
    }
}

/// Display index (0 = newest) of the most-recent Unread notification, or
/// null when every live entry has been Read. Walks newest-first so the
/// "jump to most recent unread" verb lands on the freshest pending entry.
/// Uses the same hole-skipping display mapping as `notifAt`.
pub fn firstUnreadNotif(self: *const App) ?usize {
    return self.notif_log.firstUnread();
}

/// Mark a single entry (by display index) Read and adjust the unread badge
/// down by one (saturating at 0) so the badge tracks the per-entry state.
/// Used when the user jumps to one entry rather than viewing the whole
/// panel. Returns true when the entry existed and flipped Unread→Read.
pub fn markNotifEntryRead(self: *App, display_idx: usize) bool {
    var seen: usize = 0;
    const cap = NOTIF_LOG_CAP;
    var offset: usize = 0;
    while (offset < cap) : (offset += 1) {
        const idx = (self.notif_log.next + cap - 1 - offset) % cap;
        if (self.notif_log.slots[idx]) |*entry| {
            if (seen == display_idx) {
                if (entry.read) return false;
                entry.read = true;
                if (self.notif_log.unread > 0) self.notif_log.unread -= 1;
                // Unread → Read for one entry: lower the taskbar badge.
                refreshTaskbarBadges(self);
                return true;
            }
            seen += 1;
        }
    }
    return false;
}

/// Toggle the read/unread state of a single entry (by display index).
/// If the entry is Unread, mark it Read (decrement badge); if Read,
/// mark it Unread (increment badge). Repaints the sidebar and taskbar
/// badge. Returns true when the entry existed and was toggled.
pub fn toggleNotifRead(self: *App, display_idx: usize) bool {
    var seen: usize = 0;
    const cap = NOTIF_LOG_CAP;
    var offset: usize = 0;
    while (offset < cap) : (offset += 1) {
        const idx = (self.notif_log.next + cap - 1 - offset) % cap;
        if (self.notif_log.slots[idx]) |*entry| {
            if (seen == display_idx) {
                if (entry.read) {
                    // Read → Unread: re-flag as unread.
                    entry.read = false;
                    self.notif_log.unread += 1;
                } else {
                    // Unread → Read.
                    entry.read = true;
                    if (self.notif_log.unread > 0) self.notif_log.unread -= 1;
                }
                for (self.windows.items) |w| w.invalidateSidebar();
                refreshTaskbarBadges(self);
                return true;
            }
            seen += 1;
        }
    }
    return false;
}

/// Find the oldest unread notification, mark it as read, and jump to the
/// NEXT unread entry's source pane. If there are no unread entries, this
/// is a no-op. Returns true when a jump was performed.
pub fn markOldestUnreadAndJumpNext(self: *App) bool {
    // Find the oldest unread entry.
    const oldest_idx = self.notif_log.lastUnread() orelse return false;

    // Mark it read.
    _ = markNotifEntryRead(self, oldest_idx);

    // Now find the new first (newest) unread — this is the "next" unread
    // to jump to. We use firstUnread for consistency with ipcNotifyNext.
    const next_idx = firstUnreadNotif(self) orelse return false;
    const entry = notifAt(self, next_idx) orelse return false;
    const window = entry.window;
    const surface = entry.surface;

    // Validate the entry's pointers are still live (mirrors ipcNotifyNext).
    const live = blk: {
        for (self.windows.items) |w| {
            if (w == window) {
                if (w.closing) break :blk false;
                break :blk w.findLocOfSurface(surface) != null;
            }
        }
        break :blk false;
    };
    if (!live) return false;

    const jumped = jumpToSurface(self, window, surface);
    if (jumped) _ = markNotifEntryRead(self, next_idx);
    return jumped;
}

/// Drop every notification log entry and the unread badge.
pub fn clearNotifs(self: *App) void {
    self.notif_log.clear();
    for (self.windows.items) |w| w.invalidateSidebar();
    // Cleared: remove the taskbar badge entirely.
    refreshTaskbarBadges(self);
}

/// Number of live entries in the notification log.
pub fn notifCount(self: *const App) usize {
    return self.notif_log.count();
}

/// The display_idx-th newest live notification (0 = newest), or null
/// past the end. Nulled slots are skipped so display indices stay
/// contiguous; paint and hit-test resolve entries through this same
/// mapping.
pub fn notifAt(self: *const App, display_idx: usize) ?*const NotifEntry {
    return self.notif_log.at(display_idx);
}

/// Remove a desktop notification's tray icon, kill its cleanup timer,
/// and free the slot.
pub fn clearDesktopNotif(self: *App, slot: usize) void {
    self.desktop_notifs[slot] = null;
    self.timers.stop(self.desktop_notif_timers[slot]);
    self.desktop_notif_timers[slot] = 0;
    const hwnd = self.msg_hwnd orelse return;
    var nid: w32.NOTIFYICONDATAW = std.mem.zeroes(w32.NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(w32.NOTIFYICONDATAW);
    nid.hWnd = hwnd;
    nid.uID = NOTIF_DESKTOP_UID_BASE + @as(u32, @intCast(slot));
    _ = w32.Shell_NotifyIconW(w32.NIM_DELETE, &nid);
}

/// Null any desktop-notification slots that reference a window being
/// destroyed so a later balloon click can't touch freed memory (or a
/// recycled allocation at the same address). The icon and timer are
/// left for the normal timeout path; a click on the orphaned balloon
/// is a validated no-op.
pub fn dropDesktopNotifsForWindow(self: *App, window: *Window) void {
    for (&self.desktop_notifs) |*slot| {
        if (slot.*) |n| {
            if (n.window == window) slot.* = null;
        }
    }
    // Same invalidation for the sidebar notification log. Slots are
    // nulled in place (not compacted) — notifAt skips holes.
    for (&self.notif_log.slots) |*slot| {
        if (slot.*) |*entry| {
            if (entry.window == window) slot.* = null;
        }
    }
}

// ---------------------------------------------------------------------------
// apprt action reactions (moved from App.performAction in W0-A1; reached
// through api.zig from app/perform_action.zig)
// ---------------------------------------------------------------------------

/// `.ring_bell`: audible + visual bell, sidebar bell mark and log entry.
pub fn onBell(self: *App, target: apprt.Target) void {
    // Audio bell.
    _ = w32.MessageBeep(0xFFFFFFFF);
    // Visual bell: flash the taskbar button if the window owning
    // this surface isn't currently the foreground window. Without
    // this, BEL on a backgrounded terminal is invisible.
    switch (target) {
        .app => {},
        .surface => |core_surface| {
            const rt_surface = core_surface.rt_surface;
            const parent_window = rt_surface.parent_window;
            var foreground = false;
            if (parent_window.hwnd) |win_hwnd| {
                foreground = w32.GetForegroundWindow() == win_hwnd;
                if (!foreground) {
                    var fwi: w32.FLASHWINFO = .{
                        .cbSize = @sizeOf(w32.FLASHWINFO),
                        .hwnd = win_hwnd,
                        .dwFlags = w32.FLASHW_ALL | w32.FLASHW_TIMERNOFG,
                        .uCount = 2,
                        .dwTimeout = 0,
                    };
                    _ = w32.FlashWindowEx(&fwi);
                }
            }
            // Mark the tab in the sidebar unless the bell rang
            // in the active tab of the foreground window, where
            // the user already sees it.
            const loc = parent_window.findLocOfSurface(rt_surface);
            const active = if (loc) |l|
                l.ws == parent_window.activeWorkspace() and l.container == l.ws.focused_container and l.tab == l.container.active_tab
            else
                false;
            if (!active or !foreground) {
                parent_window.setTabStatusForSurface(rt_surface, .bell);
                const title: []const u16 = if (loc) |l|
                    l.container.tab_titles[l.tab][0..l.container.tab_title_lens[l.tab]]
                else
                    std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");
                pushNotif(
                    self,
                    .bell,
                    parent_window,
                    rt_surface,
                    title,
                    std.unicode.utf8ToUtf16LeStringLiteral("Bell"),
                );
            }
        },
    }
}

/// `.show_child_exited`: mark the tab exited, log it, and report a
/// non-zero exit code in a message box.
pub fn onChildExited(self: *App, target: apprt.Target, value: apprt.Action.Value(.show_child_exited)) void {
    switch (target) {
        .app => {},
        .surface => |core_surface| {
            const rt_surface = core_surface.rt_surface;
            const parent_window = rt_surface.parent_window;
            // Mark the tab in the sidebar even when it's the
            // active tab; the user may be looking elsewhere
            // when the shell exits.
            parent_window.setTabStatusForSurface(rt_surface, .exited);
            const title: []const u16 = if (parent_window.findLocOfSurface(rt_surface)) |l|
                l.container.tab_titles[l.tab][0..l.container.tab_title_lens[l.tab]]
            else
                std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");
            pushNotif(
                self,
                .exited,
                parent_window,
                rt_surface,
                title,
                std.unicode.utf8ToUtf16LeStringLiteral("Process exited"),
            );
            const exit_code = value.exit_code;
            if (exit_code != 0) {
                // Show a message box including the actual exit code.
                const hwnd_val = rt_surface.parent_window.hwnd;
                var utf8_buf: [128]u8 = undefined;
                const msg_utf8 = std.fmt.bufPrint(
                    &utf8_buf,
                    "The shell process exited with code {d}.",
                    .{exit_code},
                ) catch "The shell process exited unexpectedly.";

                var utf16_buf: [256]u16 = undefined;
                const utf16_len = std.unicode.utf8ToUtf16Le(&utf16_buf, msg_utf8) catch {
                    _ = w32.MessageBoxW(
                        hwnd_val,
                        std.unicode.utf8ToUtf16LeStringLiteral("The shell process exited unexpectedly."),
                        std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
                        w32.MB_ICONWARNING,
                    );
                    return;
                };
                utf16_buf[utf16_len] = 0;
                _ = w32.MessageBoxW(
                    hwnd_val,
                    @ptrCast(&utf16_buf),
                    std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
                    w32.MB_ICONWARNING,
                );
            }
        },
    }
}

/// `.command_finished`: flash the taskbar button on a failed command when
/// the window is not foreground.
pub fn onCommandFinished(target: apprt.Target, value: apprt.Action.Value(.command_finished)) void {
    // Flash the taskbar button if the window isn't currently the
    // foreground window. macOS bounces the dock icon for the
    // same reason. We only flash on non-zero exit codes — a
    // successful command shouldn't pull the user back.
    switch (target) {
        .app => {},
        .surface => |core_surface| {
            if (value.exit_code orelse 0 == 0) return;
            const win_hwnd = core_surface.rt_surface.parent_window.hwnd orelse return;
            const fg = w32.GetForegroundWindow();
            if (fg == win_hwnd) return;
            var fwi: w32.FLASHWINFO = .{
                .cbSize = @sizeOf(w32.FLASHWINFO),
                .hwnd = win_hwnd,
                .dwFlags = w32.FLASHW_ALL | w32.FLASHW_TIMERNOFG,
                .uCount = 3,
                .dwTimeout = 0,
            };
            _ = w32.FlashWindowEx(&fwi);
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: parseAttentionOsc recognizes the ring/clear sentinel" {
    // ring → true, clear → false.
    try testing.expectEqual(@as(?bool, true), parseAttentionOsc("@ghostty-attention:ring"));
    try testing.expectEqual(@as(?bool, false), parseAttentionOsc("@ghostty-attention:clear"));
    // Surrounding ASCII whitespace (a padded shell sequence) is trimmed.
    try testing.expectEqual(@as(?bool, true), parseAttentionOsc("  @ghostty-attention:ring\n"));
    try testing.expectEqual(@as(?bool, false), parseAttentionOsc("\t@ghostty-attention:clear "));
}

test "unit: parseAttentionOsc ignores ordinary notifications and bad verbs" {
    // An ordinary OSC 9 notification body is not the sentinel → null
    // (the caller shows a normal balloon).
    try testing.expectEqual(@as(?bool, null), parseAttentionOsc("Build finished"));
    try testing.expectEqual(@as(?bool, null), parseAttentionOsc(""));
    // Right prefix, unknown verb → null (don't toggle on garbage).
    try testing.expectEqual(@as(?bool, null), parseAttentionOsc("@ghostty-attention:"));
    try testing.expectEqual(@as(?bool, null), parseAttentionOsc("@ghostty-attention:blink"));
    try testing.expectEqual(@as(?bool, null), parseAttentionOsc("@ghostty-attention:ring extra"));
    // A body that merely contains the prefix mid-string is not a match
    // (must be at the start after trimming).
    try testing.expectEqual(@as(?bool, null), parseAttentionOsc("see @ghostty-attention:ring"));
}

test "unit: notif ring push and newest-first indexing" {
    var ring: NotifRing(u32, 4) = .{};
    try testing.expectEqual(@as(usize, 0), ring.count());
    try testing.expectEqual(@as(?*const u32, null), ring.at(0));

    ring.push(1);
    ring.push(2);
    ring.push(3);
    try testing.expectEqual(@as(usize, 3), ring.count());
    try testing.expectEqual(@as(u32, 3), ring.at(0).?.*);
    try testing.expectEqual(@as(u32, 2), ring.at(1).?.*);
    try testing.expectEqual(@as(u32, 1), ring.at(2).?.*);
    try testing.expectEqual(@as(?*const u32, null), ring.at(3));
}

test "unit: notif ring wraps at capacity dropping the oldest" {
    // The real log capacity: 70 pushes into 64 slots leave 7..70 live.
    var ring: NotifRing(u32, NOTIF_LOG_CAP) = .{};
    var i: u32 = 1;
    while (i <= 70) : (i += 1) ring.push(i);
    try testing.expectEqual(@as(usize, 64), ring.count());
    try testing.expectEqual(@as(u32, 70), ring.at(0).?.*);
    try testing.expectEqual(@as(u32, 7), ring.at(63).?.*);
    try testing.expectEqual(@as(?*const u32, null), ring.at(64));
    // Unread counts pushes, not live slots: it may exceed the capacity
    // (the sidebar badge saturates its display at "9+" regardless).
    try testing.expectEqual(@as(usize, 70), ring.unread);
}

test "unit: notif ring unread and markRead" {
    var ring: NotifRing(u32, 4) = .{};
    try testing.expect(!ring.markRead());
    ring.push(1);
    ring.push(2);
    try testing.expectEqual(@as(usize, 2), ring.unread);
    try testing.expect(ring.markRead());
    try testing.expectEqual(@as(usize, 0), ring.unread);
    try testing.expect(!ring.markRead());
    // Entries survive a read; only the badge resets.
    try testing.expectEqual(@as(usize, 2), ring.count());
}

test "unit: notif ring clear drops entries and unread" {
    var ring: NotifRing(u32, 4) = .{};
    ring.push(1);
    ring.push(2);
    ring.clear();
    try testing.expectEqual(@as(usize, 0), ring.count());
    try testing.expectEqual(@as(usize, 0), ring.unread);
    try testing.expectEqual(@as(?*const u32, null), ring.at(0));
    // The ring is fully reusable after a clear.
    ring.push(9);
    try testing.expectEqual(@as(u32, 9), ring.at(0).?.*);
    try testing.expectEqual(@as(usize, 1), ring.unread);
}

test "unit: notif ring skips holes keeping display indices contiguous" {
    var ring: NotifRing(u32, 4) = .{};
    ring.push(1);
    ring.push(2);
    ring.push(3);
    // Null the middle entry in place (the window-destroyed
    // invalidation in dropDesktopNotifsForWindow does this).
    ring.slots[1] = null;
    try testing.expectEqual(@as(usize, 2), ring.count());
    try testing.expectEqual(@as(u32, 3), ring.at(0).?.*);
    try testing.expectEqual(@as(u32, 1), ring.at(1).?.*);
    try testing.expectEqual(@as(?*const u32, null), ring.at(2));
}

test "unit: notif ring filled exactly to capacity keeps every entry" {
    var ring: NotifRing(u32, 4) = .{};
    ring.push(1);
    ring.push(2);
    ring.push(3);
    ring.push(4);
    // next has wrapped back to slot 0 but nothing is lost yet.
    try testing.expectEqual(@as(usize, 0), ring.next);
    try testing.expectEqual(@as(usize, 4), ring.count());
    try testing.expectEqual(@as(u32, 4), ring.at(0).?.*);
    try testing.expectEqual(@as(u32, 1), ring.at(3).?.*);
    try testing.expectEqual(@as(?*const u32, null), ring.at(4));
    // The very next push is the first to drop the oldest entry.
    ring.push(5);
    try testing.expectEqual(@as(usize, 4), ring.count());
    try testing.expectEqual(@as(u32, 5), ring.at(0).?.*);
    try testing.expectEqual(@as(u32, 2), ring.at(3).?.*);
}

test "unit: notif ring cap=1 degenerate keeps only the newest" {
    var ring: NotifRing(u32, 1) = .{};
    try testing.expectEqual(@as(usize, 0), ring.count());
    ring.push(1);
    try testing.expectEqual(@as(usize, 1), ring.count());
    try testing.expectEqual(@as(u32, 1), ring.at(0).?.*);
    ring.push(2);
    try testing.expectEqual(@as(usize, 1), ring.count());
    try testing.expectEqual(@as(u32, 2), ring.at(0).?.*);
    try testing.expectEqual(@as(?*const u32, null), ring.at(1));
    // Unread counts pushes (2), not live slots (1), and resets once.
    try testing.expectEqual(@as(usize, 2), ring.unread);
    try testing.expect(ring.markRead());
    try testing.expect(!ring.markRead());
}

test "unit: notif ring push after clear restarts from a wrapped state" {
    var ring: NotifRing(u32, 4) = .{};
    var i: u32 = 1;
    while (i <= 6) : (i += 1) ring.push(i); // leaves next mid-ring (2)
    ring.clear();
    try testing.expectEqual(@as(usize, 0), ring.next);
    ring.push(7);
    ring.push(8);
    try testing.expectEqual(@as(usize, 2), ring.count());
    try testing.expectEqual(@as(u32, 8), ring.at(0).?.*);
    try testing.expectEqual(@as(u32, 7), ring.at(1).?.*);
    try testing.expectEqual(@as(?*const u32, null), ring.at(2));
    try testing.expectEqual(@as(usize, 2), ring.unread);
}

test "unit: shouldToast suppresses only when the user is looking at the source" {
    // Backgrounded window: always toast regardless of workspace/panel.
    try testing.expect(shouldToast(.{ .window_foreground = false, .workspace_active = false, .panel_open = false }));
    try testing.expect(shouldToast(.{ .window_foreground = false, .workspace_active = true, .panel_open = false }));
    try testing.expect(shouldToast(.{ .window_foreground = false, .workspace_active = true, .panel_open = true }));

    // Foreground + sending workspace is the active one: suppress (the user
    // is staring right at the source pane's workspace).
    try testing.expect(!shouldToast(.{ .window_foreground = true, .workspace_active = true, .panel_open = false }));

    // Foreground + a DIFFERENT workspace active + panel closed: toast (the
    // user can't see the notifying pane and isn't watching the log).
    try testing.expect(shouldToast(.{ .window_foreground = true, .workspace_active = false, .panel_open = false }));

    // Foreground + different workspace + panel OPEN: suppress (the user is
    // actively watching the in-app notification log).
    try testing.expect(!shouldToast(.{ .window_foreground = true, .workspace_active = false, .panel_open = true }));

    // Foreground + both true: suppress.
    try testing.expect(!shouldToast(.{ .window_foreground = true, .workspace_active = true, .panel_open = true }));
}

test "unit: notif ring unreadLive and firstUnread track per-entry read state" {
    const E = struct { v: u32, read: bool = false };
    var ring: NotifRing(E, 4) = .{};

    // Empty: nothing unread.
    try testing.expectEqual(@as(usize, 0), ring.unreadLive());
    try testing.expectEqual(@as(?usize, null), ring.firstUnread());

    ring.push(.{ .v = 1 });
    ring.push(.{ .v = 2 });
    ring.push(.{ .v = 3 });
    // All three Unread; newest (display 0) is the first unread.
    try testing.expectEqual(@as(usize, 3), ring.unreadLive());
    try testing.expectEqual(@as(?usize, 0), ring.firstUnread());

    // Mark the newest (display 0 → v=3) Read: count drops, firstUnread
    // advances to the next-newest still-unread entry (display 1 → v=2).
    // Flip the slot holding v=3 (the newest, written last at next-1).
    for (&ring.slots) |*slot| {
        if (slot.*) |*e| if (e.v == 3) {
            e.read = true;
        };
    }
    try testing.expectEqual(@as(usize, 2), ring.unreadLive());
    try testing.expectEqual(@as(?usize, 1), ring.firstUnread());

    // Mark the rest Read: nothing unread, entries still live.
    for (&ring.slots) |*slot| {
        if (slot.*) |*e| e.read = true;
    }
    try testing.expectEqual(@as(usize, 0), ring.unreadLive());
    try testing.expectEqual(@as(?usize, null), ring.firstUnread());
    try testing.expectEqual(@as(usize, 3), ring.count());
}
