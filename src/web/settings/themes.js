/**
 * Terminal theme gallery logic (pure). Native lists the themes with swatch
 * colors (`wmux.settings.list_themes`) and writes the Ghostty `theme` line of
 * the wmux overlay (`wmux.settings.set_theme`, the same writer as
 * `wmux themes set`). A theme value is one name ("Nord") or a light/dark
 * pair ("light:Builtin Light,dark:Nord").
 */
import { luminance, parseColor } from "../_shared/theme.js";
import { foldText, queryTokens } from "./schema.js";
import { t } from "./strings.js";

const MAX_NAME = 256;

function cleanName(name) {
  if (typeof name !== "string") return null;
  const trimmed = name.trim();
  if (trimmed === "" || [...trimmed].length > MAX_NAME || /[\u0000-\u001f,]/.test(trimmed)) return null;
  return trimmed;
}

/** Parse a theme value into {light, dark} or null (Ghostty default colors). */
export function parseThemeValue(value) {
  if (value && typeof value === "object" && !Array.isArray(value)) {
    const light = cleanName(value.light);
    const dark = cleanName(value.dark);
    if (!light && !dark) return null;
    return { light: light || dark, dark: dark || light };
  }
  if (typeof value !== "string" || value.trim() === "") return null;
  const text = value.trim();
  if (/(^|,)\s*(light|dark)\s*:/i.test(text)) {
    let light = null;
    let dark = null;
    for (const part of text.split(",")) {
      const m = /^\s*(light|dark)\s*:(.*)$/i.exec(part);
      if (!m) continue;
      const name = cleanName(m[2]);
      if (m[1].toLowerCase() === "light") light = name;
      else dark = name;
    }
    if (!light && !dark) return null;
    return { light: light || dark, dark: dark || light };
  }
  const name = cleanName(text);
  return name ? { light: name, dark: name } : null;
}

/** Ghostty theme line value for a pair; a single name when both halves match. */
export function formatThemeValue(pair) {
  if (!pair) return null;
  if (pair.light === pair.dark) return pair.light;
  return `light:${pair.light},dark:${pair.dark}`;
}

function colorHex(value) {
  const c = parseColor(value);
  if (!c) return null;
  const h = (n) => n.toString(16).padStart(2, "0");
  return `#${h(c.r)}${h(c.g)}${h(c.b)}`;
}

/**
 * Normalize `wmux.settings.list_themes`: {themes: [{name, scheme?,
 * background, foreground, palette?: [16]}], current?: value}. Themes without
 * a valid name are dropped; the scheme falls back to background luminance.
 * Sorted by name; duplicates keep the first.
 */
export function normalizeThemes(result) {
  const raw = result && Array.isArray(result.themes) ? result.themes : Array.isArray(result) ? result : [];
  const seen = new Set();
  const themes = [];
  for (const item of raw) {
    if (!item || typeof item !== "object") continue;
    const name = cleanName(item.name);
    if (!name || seen.has(name)) continue;
    seen.add(name);
    const background = colorHex(item.background) || "#000000";
    const foreground = colorHex(item.foreground) || "#ffffff";
    const palette = Array.isArray(item.palette) ? item.palette.slice(0, 16).map((c) => colorHex(c) || foreground) : [];
    let scheme = item.scheme === "light" || item.scheme === "dark" ? item.scheme : null;
    if (!scheme) scheme = luminance(parseColor(background)) > 0.4 ? "light" : "dark";
    themes.push({ name, scheme, background, foreground, palette });
  }
  themes.sort((a, b) => a.name.localeCompare(b.name));
  return { themes, current: parseThemeValue(result ? result.current : null) };
}

/** Themes matching the query, split into {dark, light}. */
export function groupThemes(themes, query) {
  const tokens = queryTokens(query);
  const match = (th) => tokens.every((tok) => foldText(th.name).includes(tok));
  const list = themes.filter(match);
  return { dark: list.filter((th) => th.scheme === "dark"), light: list.filter((th) => th.scheme === "light") };
}

/** "Light: X · Dark: Y", or "Ghostty default colors" without a theme. */
export function themeSummary(pair) {
  if (!pair) return t("settings.themes.defaultColors");
  return t("settings.themes.summary", { light: pair.light, dark: pair.dark });
}

/**
 * The pair after picking `theme`: it replaces the half of its scheme. When
 * the other half is unset, or a single theme of the same scheme was in use,
 * the picked theme is used for both.
 */
export function selectTheme(current, theme, themes) {
  if (!theme) return current;
  if (!current) return { light: theme.name, dark: theme.name };
  const byName = new Map((themes || []).map((th) => [th.name, th]));
  if (current.light === current.dark) {
    const prev = byName.get(current.light);
    if (!prev || prev.scheme === theme.scheme) return { light: theme.name, dark: theme.name };
    return theme.scheme === "dark"
      ? { light: current.light, dark: theme.name }
      : { light: theme.name, dark: current.dark };
  }
  return theme.scheme === "dark"
    ? { light: current.light, dark: theme.name }
    : { light: theme.name, dark: current.dark };
}
