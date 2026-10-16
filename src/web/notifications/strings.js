/**
 * Notifications panel strings. Keys are stable ids for translators (W7);
 * values are the English defaults handed to tr(). index.html carries the same
 * keys in data-i18n / data-i18n-attr attributes for its static text.
 */
import { tr } from "../_shared/strings.js";

export const STRINGS = Object.freeze({
  "notifications.title": "Notifications",
  "notifications.unreadBadge": "{count} unread",
  "notifications.jumpLatest": "Jump to Latest",
  "notifications.jumpLatestUnread": "Jump to Latest Unread",
  "notifications.clearAll": "Clear All",
  "notifications.list": "Notifications",

  "notifications.empty.title": "No notifications yet",
  "notifications.empty.bodyPopover": "Desktop notifications will appear here.",
  "notifications.empty.bodyPane": "Desktop notifications will appear here for quick review.",
  "notifications.markers.one": "1 unread notification",
  "notifications.markers.other": "{count} unread notifications",

  "notifications.group.unknown": "Other",
  "notifications.group.label": "{title}, {unread} unread",
  "notifications.row.unread": "Unread",
  "notifications.row.clear": "Clear notification",
  "notifications.row.workspaceLevel": "Workspace",

  "notifications.menu.label": "Notification actions",
  "notifications.menu.open": "Open",
  "notifications.menu.copy": "Copy",
  "notifications.menu.markRead": "Mark as Read",
  "notifications.menu.markUnread": "Mark as Unread",
  "notifications.menu.dismiss": "Dismiss",

  "notifications.status.copied": "Copied",
  "notifications.status.offline": "Not running inside wmux.",
  "notifications.status.loadFailed": "Could not load notifications: {message}",
  "notifications.status.actionFailed": "Could not complete the action: {message}",
  "notifications.status.nothingUnread": "No unread notifications",
});

/**
 * Translate a notifications panel string.
 * @param {keyof typeof STRINGS | string} key
 * @param {Record<string, unknown>} [params]
 */
export function t(key, params) {
  const fallback = Object.prototype.hasOwnProperty.call(STRINGS, key) ? STRINGS[key] : key;
  return tr(key, fallback, params);
}
