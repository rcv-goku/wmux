//! Public API of the `notifications` feature. Other features and the
//! app/rpc/ui layers reach notifications only through this file
//! (ARCHITECTURE.md ADR-1.2). In W0-A1 it re-exports the legacy ring
//! (`legacy_ring.zig`); W2-5 replaces the implementation with the
//! notification store and delivery pipeline (ADR-7) behind the same
//! entry points where it can.

const ring = @import("legacy_ring.zig");

// State types still embedded in App (W0-A3 moves them to ext state).
pub const NOTIF_DESKTOP_SLOTS = ring.NOTIF_DESKTOP_SLOTS;
pub const NOTIF_DESKTOP_UID_BASE = ring.NOTIF_DESKTOP_UID_BASE;
pub const NOTIF_LOG_CAP = ring.NOTIF_LOG_CAP;
pub const DesktopNotif = ring.DesktopNotif;
pub const NotifEntry = ring.NotifEntry;
pub const NotifRing = ring.NotifRing;

// Ingestion (apprt actions routed by app/perform_action.zig, and pushes).
pub const showDesktopNotification = ring.showDesktopNotification;
pub const onBell = ring.onBell;
pub const onChildExited = ring.onChildExited;
pub const onCommandFinished = ring.onCommandFinished;
pub const pushNotif = ring.pushNotif;

// Desktop balloons.
pub const onDesktopNotifClick = ring.onDesktopNotifClick;
pub const clearDesktopNotif = ring.clearDesktopNotif;
pub const dropDesktopNotifsForWindow = ring.dropDesktopNotifsForWindow;

// Notification log (sidebar panel) and unread state.
pub const notifCount = ring.notifCount;
pub const notifAt = ring.notifAt;
pub const markNotifsRead = ring.markNotifsRead;
pub const markNotifEntryRead = ring.markNotifEntryRead;
pub const toggleNotifRead = ring.toggleNotifRead;
pub const markOldestUnreadAndJumpNext = ring.markOldestUnreadAndJumpNext;
pub const clearNotifs = ring.clearNotifs;
pub const jumpToSurface = ring.jumpToSurface;
