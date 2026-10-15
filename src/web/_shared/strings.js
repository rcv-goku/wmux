/**
 * Tiny i18n helper for wmux web panels; the web twin of native
 * ui/strings.zig tr("feature.key", "English default") (ARCHITECTURE §15.4).
 *
 *   import { tr } from "../_shared/strings.js";
 *   tr("about.copy", "Copy version info");
 *   tr("about.version", "Version {version}", { version: "1.2.0" });
 *
 * Until localization lands (W7) no catalogs are registered, so tr() returns
 * the English default. Panels keep their keys and defaults in
 * src/web/<app>/strings.js. Static HTML can carry keys too:
 *
 *   <h1 data-i18n="about.title">About wmux</h1>
 *   <button data-i18n-attr="title:about.copy.tip">...</button>
 *
 * and applyStrings() replaces the text/attributes with translations (the markup
 * text is the English default).
 */

const catalogs = new Map();
let locale = normalizeLocale(initialLocale());

/** Attributes applyStrings() may set; everything else is ignored. */
const TRANSLATABLE_ATTRIBUTES = new Set([
  "title",
  "alt",
  "label",
  "placeholder",
  "aria-label",
  "aria-description",
  "aria-placeholder",
  "aria-roledescription",
  "aria-valuetext",
]);

function initialLocale() {
  if (typeof document !== "undefined" && document.documentElement) {
    const lang = document.documentElement.getAttribute("lang");
    if (lang) return lang;
  }
  if (typeof navigator !== "undefined" && navigator.language) return navigator.language;
  return "en";
}

function normalizeLocale(value) {
  const text = typeof value === "string" ? value.trim().replace(/_/g, "-").toLowerCase() : "";
  return text === "" ? "en" : text;
}

function lookup(key) {
  const candidates = [locale];
  const dash = locale.indexOf("-");
  if (dash > 0) candidates.push(locale.slice(0, dash));
  for (const candidate of candidates) {
    const table = catalogs.get(candidate);
    if (table && table.has(key)) return table.get(key);
  }
  return undefined;
}

/**
 * Translate `key`, falling back to `fallback` (the English default), then to the key.
 * `{name}` placeholders are replaced from `params`.
 *
 * @param {string} key
 * @param {string} [fallback]
 * @param {Record<string, unknown>} [params]
 * @returns {string}
 */
export function tr(key, fallback, params) {
  const id = String(key);
  let text = lookup(id);
  if (text === undefined) {
    text = fallback === undefined || fallback === null ? id : String(fallback);
  }
  return params ? format(text, params) : text;
}

/**
 * Replace `{name}` placeholders. Unknown or nullish names are left as written.
 *
 * @param {string} template
 * @param {Record<string, unknown>} params
 */
export function format(template, params) {
  return String(template).replace(/\{([A-Za-z0-9_]+)\}/g, (match, name) => {
    if (!params || !Object.prototype.hasOwnProperty.call(params, name)) return match;
    const value = params[name];
    return value === undefined || value === null ? match : String(value);
  });
}

/**
 * Register translations for a locale ("de", "pt-BR", ...). Later calls merge.
 *
 * @param {string} localeName
 * @param {Record<string, string>} table key -> translated text
 */
export function addStrings(localeName, table) {
  const id = normalizeLocale(localeName);
  let map = catalogs.get(id);
  if (!map) {
    map = new Map();
    catalogs.set(id, map);
  }
  if (table && typeof table === "object") {
    for (const key of Object.keys(table)) {
      if (typeof table[key] === "string") map.set(key, table[key]);
    }
  }
}

/** Current locale (lowercase BCP 47, e.g. "en", "de-at"). */
export function getLocale() {
  return locale;
}

/** Switch the locale used by tr(); updates <html lang>. */
export function setLocale(localeName) {
  locale = normalizeLocale(localeName);
  if (typeof document !== "undefined" && document.documentElement) {
    document.documentElement.setAttribute("lang", locale);
  }
}

/**
 * Translate [data-i18n] text and [data-i18n-attr] attributes under `root`.
 * data-i18n="key" replaces the element's text (the current text is the default);
 * data-i18n-attr="title:key1; aria-label:key2" replaces attributes.
 *
 * @param {ParentNode} [root] defaults to document
 */
export function applyStrings(root) {
  const scope = root || (typeof document !== "undefined" ? document : null);
  if (!scope || typeof scope.querySelectorAll !== "function") return;

  for (const el of Array.from(scope.querySelectorAll("[data-i18n]"))) {
    const key = el.getAttribute("data-i18n");
    if (key) el.textContent = tr(key, el.textContent.replace(/\s+/g, " ").trim());
  }

  for (const el of Array.from(scope.querySelectorAll("[data-i18n-attr]"))) {
    const spec = el.getAttribute("data-i18n-attr") || "";
    for (const part of spec.split(";")) {
      const colon = part.indexOf(":");
      if (colon <= 0) continue;
      const attr = part.slice(0, colon).trim().toLowerCase();
      const key = part.slice(colon + 1).trim();
      if (!key || !TRANSLATABLE_ATTRIBUTES.has(attr)) continue;
      el.setAttribute(attr, tr(key, el.getAttribute(attr) || ""));
    }
  }
}
