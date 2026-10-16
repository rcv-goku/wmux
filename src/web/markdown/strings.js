/**
 * Markdown panel strings. Keys are stable ids for translators (W7); values are
 * the English defaults handed to tr(). index.html carries the same keys in
 * data-i18n / data-i18n-attr attributes for its static text.
 */
import { tr } from "../_shared/strings.js";

export const STRINGS = Object.freeze({
  "markdown.title": "Markdown",
  "markdown.toolbar": "Markdown viewer",

  "markdown.refresh": "Refresh",
  "markdown.showText": "Show TextEdit",
  "markdown.showPreview": "Show Preview",
  "markdown.revert": "Revert",
  "markdown.save": "Save",
  "markdown.editor.label": "Markdown source",
  "markdown.find": "Find",
  "markdown.copyMarkdown": "Copy as Markdown",
  "markdown.copyHtml": "Copy as HTML",
  "markdown.copiedMarkdown": "Copied as Markdown",
  "markdown.copiedHtml": "Copied as HTML",
  "markdown.copyFailed": "Could not copy: {message}",
  "markdown.typography": "Font Size",

  "markdown.copyCode": "Copy code",
  "markdown.copied": "Copied",

  "markdown.frontmatter": "Show frontmatter",

  "markdown.find.placeholder": "Find",
  "markdown.find.label": "Find in document",
  "markdown.find.previous": "Previous match",
  "markdown.find.next": "Next match",
  "markdown.find.close": "Close find bar",
  "markdown.find.count": "{current}/{total}",
  "markdown.find.unavailable": "Find is not available in TextEdit mode.",

  "markdown.typo.title": "Typography",
  "markdown.typo.font": "Font",
  "markdown.typo.system": "System",
  "markdown.typo.size": "Size (pt)",
  "markdown.typo.maxWidth": "Max Width (px)",
  "markdown.typo.reset": "Reset to default",
  "markdown.typo.resetBuiltin": "Reset to built-in defaults",
  "markdown.typo.setDefault": "Set as default for new viewers",
  "markdown.typo.savedDefault": "Saved as the default for new viewers",
  "markdown.typo.saveDefaultFailed": "Could not save the defaults: {message}",

  "markdown.unavailable.title": "File unavailable",
  "markdown.unavailable.body":
    "The file was moved, deleted or cannot be read. The viewer reloads it when it is back.",

  "markdown.image.blocked": "Remote image blocked",
  "markdown.image.blockedBody": "wmux will not contact this image URL until you load this image.",
  "markdown.image.load": "Load image",
  "markdown.image.open": "Open URL",
  "markdown.image.copy": "Copy URL",
  "markdown.image.loadFailed": "Could not load the image: {message}",

  "markdown.diagram.error": "{library} error: {message}",
  "markdown.diagram.tooLarge": "the diagram source is too large",
  "markdown.diagram.loading": "Rendering diagram…",

  "markdown.link.openFile": "Open {path}",
  "markdown.link.failed": "Could not open the link: {message}",
  "markdown.link.notFound": "File not found: {path}",

  "markdown.status.loading": "Loading…",
  "markdown.status.offline": "Not running inside wmux.",
  "markdown.status.loadFailed": "Could not read the file: {message}",
  "markdown.status.saved": "Saved",
  "markdown.status.saveFailed": "Could not save: {message}",
  "markdown.status.changedOnDisk": "The file changed on disk. Save to overwrite it or Revert to load it.",
  "markdown.status.deletedOnDisk": "The file was deleted on disk. Save to write it again.",
});

/**
 * Translate a markdown panel string.
 * @param {keyof typeof STRINGS | string} key
 * @param {Record<string, unknown>} [params]
 */
export function t(key, params) {
  const fallback = Object.prototype.hasOwnProperty.call(STRINGS, key) ? STRINGS[key] : key;
  return tr(key, fallback, params);
}
