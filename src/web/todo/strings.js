/**
 * Todos pane strings. Keys are stable ids for translators (W7); values are the
 * English defaults handed to tr(). index.html carries the same keys in
 * data-i18n / data-i18n-attr attributes for its static text.
 */
import { tr } from "../_shared/strings.js";

export const STRINGS = Object.freeze({
  "todo.title": "Todos",
  "todo.status": "Workspace status",
  "todo.progress": "{completed} of {total} completed",
  "todo.list": "Checklist",
  "todo.empty": "No checklist items yet.",
  "todo.unavailable": "This workspace is no longer available.",
  "todo.add.placeholder": "New checklist item",
  "todo.add.button": "Add item",
  "todo.clear": "Clear",
  "todo.clear.confirm": "Remove all {total} checklist items?",
  "todo.clear.ok": "Clear",
  "todo.cancel": "Cancel",

  "todo.check": "Mark as completed",
  "todo.uncheck": "Mark as pending",
  "todo.agent": "agent",
  "todo.agentTip": "Added by an agent",
  "todo.inProgress": "In progress",
  "todo.edit.label": "Item text",

  "todo.menu.label": "Item actions",
  "todo.menu.edit": "Edit",
  "todo.menu.start": "Mark In Progress",
  "todo.menu.pending": "Mark as Pending",
  "todo.menu.complete": "Mark as Completed",
  "todo.menu.remove": "Remove",
  "todo.menu.attach": "Attach Images…",
  "todo.menu.open": "Open",
  "todo.menu.removeAttachment": "Remove Attachment",

  "todo.attach.tip": "Manage images",
  "todo.attach.none": "No images attached. Attach images.",
  "todo.attach.one": "1 image attached",
  "todo.attach.many": "{count} images attached",
  "todo.attach.unnamed": "image {n}",

  "todo.error.full": "The checklist is full ({max} items).",
  "todo.error.empty": "Enter some text first.",
  "todo.error.invalid": "The text contains invalid characters.",
  "todo.error.failed": "Could not update the checklist: {message}",
  "todo.error.load": "Could not load the checklist: {message}",
  "todo.error.malformed": "malformed reply",
  "todo.offline": "Not running inside wmux.",
});

/**
 * Translate a Todos pane string.
 * @param {keyof typeof STRINGS | string} key
 * @param {Record<string, unknown>} [params]
 */
export function t(key, params) {
  const fallback = Object.prototype.hasOwnProperty.call(STRINGS, key) ? STRINGS[key] : key;
  return tr(key, fallback, params);
}

/** a11y text of the paperclip control for `count` attachments. */
export function attachmentsLabel(count) {
  if (!count) return t("todo.attach.none");
  if (count === 1) return t("todo.attach.one");
  return t("todo.attach.many", { count });
}
