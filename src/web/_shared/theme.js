/**
 * Theme sync for wmux web panels (ARCHITECTURE ADR-6.6).
 *
 * Native pushes the terminal theme in panel.init.theme and in "theme" events
 * (on every config change). Importing this module wires both to CSS custom
 * properties on <html>; theme.css declares every --wmux-* token with its default.
 *
 *   import "../_shared/theme.js";                  // automatic sync
 *   import { onThemeChange } from "../_shared/theme.js";
 *   onThemeChange((theme) => redrawCanvas(theme)); // normalized theme object
 *
 * Also sets on <html>:
 *   data-wmux-theme="host" | "default"   (no attribute until the first theme)
 *   data-wmux-scheme="dark" | "light"
 *   data-wmux-high-contrast="true"       (SPI_GETHIGHCONTRAST)
 *   data-wmux-reduced-motion="true"      (optional host flag)
 * and dispatches a "wmux:themechange" CustomEvent on document.
 *
 * Accepted payload keys (snake_case canonical; kebab-case and camelCase also work):
 *   background, foreground, palette[16], cursor | cursor_color, cursor_text,
 *   selection | selection_background, selection_foreground, accent,
 *   font_family (string or array), font_size_px (CSS px, not physical pixels;
 *   a bare font_size is read as px too) | font_size_pt,
 *   background_opacity (0..1), scheme ("dark"|"light"), high_contrast,
 *   reduced_motion, sidebar {background, foreground, active_background,
 *   active_foreground, border}.
 * Colors: "#rgb", "#rrggbb", "#rrggbbaa" (alpha ignored), bare hex,
 * "rgb(r, g, b)", {r, g, b} or [r, g, b] with 0..255 channels.
 */
import { wmux } from "./wmux-bridge.js";

/** Terminal palette used when the host sends none (Tango, public domain). */
const DEFAULT_PALETTE = [
  "#2e3436",
  "#cc0000",
  "#4e9a06",
  "#c4a000",
  "#3465a4",
  "#75507b",
  "#06989a",
  "#d3d7cf",
  "#555753",
  "#ef2929",
  "#8ae234",
  "#fce94f",
  "#729fcf",
  "#ad7fa8",
  "#34e2e2",
  "#eeeeec",
];

const DEFAULT_COLORS = {
  dark: { background: "#1e1e1e", foreground: "#d4d4d4", accent: "#4c9aff" },
  light: { background: "#ffffff", foreground: "#1f1f1f", accent: "#0b62d6" },
};

const MONO_FALLBACKS = ["Cascadia Mono", "Consolas", "Courier New"];
const DEFAULT_FONT_SIZE_PX = 14;
const MIN_FONT_SIZE_PX = 6;
const MAX_FONT_SIZE_PX = 96;
const MAX_FONT_FAMILIES = 8;
const MAX_FONT_NAME_LENGTH = 128;

const BLACK = { r: 0, g: 0, b: 0 };
const WHITE = { r: 255, g: 255, b: 255 };
const HEX_RE = /^#?([0-9a-f]{3}|[0-9a-f]{4}|[0-9a-f]{6}|[0-9a-f]{8})$/i;
const RGB_RE = /^rgba?\(\s*(\d{1,3})\s*[,\s]\s*(\d{1,3})\s*[,\s]\s*(\d{1,3})\s*(?:[,/][^)]*)?\)$/i;

/**
 * Parse a color into {r, g, b} (0..255 integers), or null if unrecognized.
 * @param {unknown} value
 */
export function parseColor(value) {
  if (typeof value === "string") {
    const text = value.trim();
    const hex = HEX_RE.exec(text);
    if (hex) return parseHex(hex[1]);
    const rgb = RGB_RE.exec(text);
    if (rgb) return fromChannels(Number(rgb[1]), Number(rgb[2]), Number(rgb[3]));
    return null;
  }
  if (Array.isArray(value)) {
    return value.length >= 3 ? fromChannels(value[0], value[1], value[2]) : null;
  }
  if (value && typeof value === "object") {
    return fromChannels(value.r, value.g, value.b);
  }
  return null;
}

function parseHex(digits) {
  let full = digits;
  if (digits.length <= 4) {
    full = "";
    for (const ch of digits) full += ch + ch;
  }
  return {
    r: parseInt(full.slice(0, 2), 16),
    g: parseInt(full.slice(2, 4), 16),
    b: parseInt(full.slice(4, 6), 16),
  };
}

function fromChannels(r, g, b) {
  const channels = [r, g, b];
  for (const c of channels) {
    if (typeof c !== "number" || !isFinite(c) || c < 0 || c > 255) return null;
  }
  return { r: Math.round(r), g: Math.round(g), b: Math.round(b) };
}

/** "#rrggbb" for a parsed color. */
export function toHex(color) {
  const part = (n) => (n < 16 ? "0" : "") + n.toString(16);
  return "#" + part(color.r) + part(color.g) + part(color.b);
}

/** WCAG relative luminance (0 = black, 1 = white). */
export function luminance(color) {
  const lin = (n) => {
    const s = n / 255;
    return s <= 0.04045 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
  };
  return 0.2126 * lin(color.r) + 0.7152 * lin(color.g) + 0.0722 * lin(color.b);
}

/** WCAG contrast ratio between two colors (1..21). */
export function contrastRatio(a, b) {
  const la = luminance(a);
  const lb = luminance(b);
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

/** Linear sRGB interpolation from a (t = 0) to b (t = 1). */
export function mix(a, b, t) {
  return {
    r: Math.round(a.r + (b.r - a.r) * t),
    g: Math.round(a.g + (b.g - a.g) * t),
    b: Math.round(a.b + (b.b - a.b) * t),
  };
}

/** Black or white, whichever contrasts more with `bg`. */
function bestTextOn(bg) {
  return contrastRatio(WHITE, bg) >= contrastRatio(BLACK, bg) ? WHITE : BLACK;
}

/** `preferred` if it reaches `min` contrast on `bg`, else black or white. */
function readableOn(preferred, bg, min) {
  return contrastRatio(preferred, bg) >= min ? preferred : bestTextOn(bg);
}

/** The most muted mix of fg toward bg that still reaches 4.5:1 on bg. */
function mutedOn(fg, bg) {
  for (const t of [0.4, 0.32, 0.24, 0.16, 0.08]) {
    const candidate = mix(fg, bg, t);
    if (contrastRatio(candidate, bg) >= 4.5) return candidate;
  }
  return fg;
}

function firstReadable(candidates, bg, min, fallback) {
  for (const c of candidates) {
    if (c && contrastRatio(c, bg) >= min) return c;
  }
  return fallback;
}

/** Look up a key in snake_case, kebab-case or camelCase; first non-null wins. */
function pick(source, ...names) {
  if (!source || typeof source !== "object") return undefined;
  for (const name of names) {
    const keys = [
      name,
      name.replace(/_/g, "-"),
      name.replace(/_([a-z0-9])/g, (m, c) => c.toUpperCase()),
    ];
    for (const key of keys) {
      if (Object.prototype.hasOwnProperty.call(source, key)) {
        const value = source[key];
        if (value !== undefined && value !== null) return value;
      }
    }
  }
  return undefined;
}

/** A nested object such as {background, foreground} (not an {r, g, b} color), or null. */
function nestedObject(value) {
  if (!value || typeof value !== "object" || Array.isArray(value) || "r" in value) return null;
  return value;
}

function normalizePalette(raw, fallback) {
  const palette = [];
  for (let i = 0; i < 16; i += 1) {
    const color = Array.isArray(raw) ? parseColor(raw[i]) : null;
    palette.push(color || fallback[i]);
  }
  return palette;
}

function normalizeFontFamilies(raw) {
  let names = [];
  if (Array.isArray(raw)) names = raw;
  else if (typeof raw === "string") names = raw.split(",");
  const out = [];
  for (const entry of names) {
    if (typeof entry !== "string") continue;
    // Strip control characters and one pair of wrapping quotes; CSS quoting happens later.
    let name = entry.replace(/[\u0000-\u001f\u007f]/g, "").trim();
    const quote = name.charAt(0);
    if (name.length >= 2 && (quote === '"' || quote === "'") && name.endsWith(quote)) {
      name = name.slice(1, -1).trim();
    }
    name = name.slice(0, MAX_FONT_NAME_LENGTH);
    if (name !== "" && out.indexOf(name) < 0) out.push(name);
    if (out.length >= MAX_FONT_FAMILIES) break;
  }
  return out;
}

function normalizeFontSize(source) {
  let px = Number(pick(source, "font_size_px", "font_size"));
  if (!(px > 0)) {
    const pt = Number(pick(source, "font_size_pt"));
    px = pt > 0 ? (pt * 96) / 72 : DEFAULT_FONT_SIZE_PX;
  }
  px = Math.min(MAX_FONT_SIZE_PX, Math.max(MIN_FONT_SIZE_PX, px));
  return Math.round(px * 100) / 100;
}

function normalizeScheme(value) {
  const text = typeof value === "string" ? value.trim().toLowerCase() : "";
  return text === "dark" || text === "light" ? text : null;
}

/** CSS font-family list: host families first, then Windows monospace fallbacks. */
export function fontFamilyList(families) {
  const all = families.slice();
  for (const name of MONO_FALLBACKS) if (all.indexOf(name) < 0) all.push(name);
  return all.map((name) => '"' + name.replace(/["\\]/g, "\\$&") + '"').join(", ") + ", monospace";
}

/** The scheme the WebView2 profile prefers (follows the OS unless native overrides it). */
export function preferredScheme() {
  if (typeof matchMedia === "function" && matchMedia("(prefers-color-scheme: light)").matches) {
    return "light";
  }
  return "dark";
}

/**
 * Normalize a host theme payload (or null for defaults) into a complete theme.
 * Missing values get defaults; derived colors are chosen for WCAG contrast.
 *
 * @param {object|null} raw
 * @param {"dark"|"light"} [fallbackScheme] used when neither scheme nor background is given
 */
export function normalizeTheme(raw, fallbackScheme) {
  const isHost = Boolean(raw) && typeof raw === "object" && !Array.isArray(raw);
  const src = isHost ? raw : {};

  const backgroundIn = parseColor(pick(src, "background", "bg"));
  let scheme = normalizeScheme(pick(src, "scheme"));
  if (!scheme && backgroundIn) scheme = bestTextOn(backgroundIn) === WHITE ? "dark" : "light";
  if (!scheme) scheme = fallbackScheme === "light" ? "light" : "dark";

  const defaults = DEFAULT_COLORS[scheme];
  const background = backgroundIn || parseColor(defaults.background);
  const foreground =
    parseColor(pick(src, "foreground", "fg")) || parseColor(defaults.foreground);
  const palette = normalizePalette(
    pick(src, "palette", "ansi"),
    DEFAULT_PALETTE.map((hex) => parseColor(hex)),
  );
  const accent =
    parseColor(pick(src, "accent", "accent_color")) || parseColor(defaults.accent);

  // cursor: a color, or {color, text}; cursor_color / cursor_text win when present.
  const cursorRaw = pick(src, "cursor");
  const cursorNested = nestedObject(cursorRaw);
  const cursor =
    parseColor(pick(src, "cursor_color")) ||
    parseColor(cursorNested ? pick(cursorNested, "color", "background") : cursorRaw) ||
    foreground;
  const cursorText =
    parseColor(pick(src, "cursor_text")) ||
    parseColor(cursorNested ? pick(cursorNested, "text", "foreground") : null) ||
    background;

  // selection: a background color, or {background, foreground}.
  const selectionRaw = pick(src, "selection");
  const selectionNested = nestedObject(selectionRaw);
  const selectionBackground =
    parseColor(pick(src, "selection_background")) ||
    parseColor(selectionNested ? pick(selectionNested, "background", "bg") : selectionRaw) ||
    mix(background, accent, 0.35);
  const selectionForeground = readableOn(
    parseColor(pick(src, "selection_foreground")) ||
      parseColor(selectionNested ? pick(selectionNested, "foreground", "fg") : null) ||
      foreground,
    selectionBackground,
    3,
  );

  const opacity = Number(pick(src, "background_opacity", "opacity"));
  const backgroundOpacity = opacity >= 0 && opacity <= 1 ? opacity : 1;
  const highContrast = pick(src, "high_contrast") === true;
  const reducedMotion = pick(src, "reduced_motion") === true;

  // sidebar: nested object, or flat sidebar_* keys.
  const sb = nestedObject(pick(src, "sidebar")) || {};
  const sidebarBackground =
    parseColor(pick(sb, "background", "bg")) ||
    parseColor(pick(src, "sidebar_background")) ||
    mix(background, foreground, 0.04);
  const sidebarForeground =
    parseColor(pick(sb, "foreground", "fg", "text")) ||
    parseColor(pick(src, "sidebar_foreground")) ||
    foreground;
  const sidebarActiveBackground =
    parseColor(pick(sb, "active_background", "selected_background")) ||
    parseColor(pick(src, "sidebar_active_background")) ||
    mix(sidebarBackground, accent, 0.25);
  const sidebarActiveForeground = readableOn(
    parseColor(pick(sb, "active_foreground", "selected_foreground")) ||
      parseColor(pick(src, "sidebar_active_foreground")) ||
      sidebarForeground,
    sidebarActiveBackground,
    4.5,
  );
  const sidebarBorder =
    parseColor(pick(sb, "border")) ||
    parseColor(pick(src, "sidebar_border")) ||
    mix(sidebarBackground, sidebarForeground, 0.15);

  return {
    source: isHost ? "host" : "default",
    scheme,
    background,
    foreground,
    palette,
    accent,
    accentForeground: bestTextOn(accent),
    cursor,
    cursorText,
    selectionBackground,
    selectionForeground,
    fontFamilies: normalizeFontFamilies(pick(src, "font_family", "font_families")),
    fontSizePx: normalizeFontSize(src),
    backgroundOpacity,
    highContrast,
    reducedMotion,
    mutedForeground: mutedOn(foreground, background),
    focusRing: firstReadable([accent], background, 3, foreground),
    link: firstReadable([accent, palette[12], palette[4]], background, 4.5, foreground),
    sidebar: {
      background: sidebarBackground,
      foreground: sidebarForeground,
      activeBackground: sidebarActiveBackground,
      activeForeground: sidebarActiveForeground,
      border: sidebarBorder,
    },
  };
}

/**
 * The CSS custom properties for a normalized theme, as [name, value] pairs.
 * theme.css declares the same names with default values.
 */
export function themeProperties(theme) {
  const bg = theme.background;
  const fg = theme.foreground;
  const hc = theme.highContrast;
  const props = [];
  const color = (name, c) => props.push(["--wmux-" + name, toHex(c)]);
  const triplet = (c) => c.r + " " + c.g + " " + c.b;

  color("bg", bg);
  color("fg", fg);
  props.push(["--wmux-bg-rgb", triplet(bg)]);
  props.push(["--wmux-fg-rgb", triplet(fg)]);
  props.push(["--wmux-bg-opacity", String(theme.backgroundOpacity)]);
  theme.palette.forEach((c, i) => color("palette-" + i, c));
  color("cursor", theme.cursor);
  color("cursor-text", theme.cursorText);
  color("selection-bg", theme.selectionBackground);
  color("selection-fg", theme.selectionForeground);
  color("accent", theme.accent);
  color("accent-fg", theme.accentForeground);
  props.push(["--wmux-accent-rgb", triplet(theme.accent)]);
  color("sidebar-bg", theme.sidebar.background);
  color("sidebar-fg", theme.sidebar.foreground);
  color("sidebar-active-bg", theme.sidebar.activeBackground);
  color("sidebar-active-fg", theme.sidebar.activeForeground);
  color("sidebar-border", theme.sidebar.border);
  props.push(["--wmux-font-mono", fontFamilyList(theme.fontFamilies)]);
  props.push(["--wmux-font-size", theme.fontSizePx + "px"]);

  // Derived UI tokens (stay in step with the defaults in theme.css).
  color("surface", mix(bg, fg, 0.04));
  color("surface-raised", mix(bg, fg, 0.08));
  color("hover", mix(bg, fg, 0.1));
  color("pressed", mix(bg, fg, 0.16));
  color("border", mix(bg, fg, hc ? 0.6 : 0.18));
  color("border-strong", mix(bg, fg, hc ? 0.85 : 0.32));
  color("fg-muted", hc ? fg : theme.mutedForeground);
  color("focus-ring", theme.focusRing);
  color("link", theme.link);
  color("scrollbar-thumb", mix(bg, fg, hc ? 0.6 : 0.28));
  color("scrollbar-thumb-hover", mix(bg, fg, hc ? 0.8 : 0.42));
  return props;
}

let currentNormalized = null;
const listeners = new Set();
const appliedNames = new WeakMap();

/**
 * Apply a host theme payload, or null for the defaults (theme.css values that
 * follow prefers-color-scheme). Returns the normalized theme.
 *
 * @param {object|null} raw
 * @param {HTMLElement} [root] defaults to document.documentElement
 */
export function applyTheme(raw, root) {
  const el = root || (typeof document !== "undefined" ? document.documentElement : null);
  const theme = normalizeTheme(raw, preferredScheme());
  if (el) {
    const previous = appliedNames.get(el) || [];
    for (const name of previous) el.style.removeProperty(name);
    const names = [];
    if (theme.source === "host") {
      for (const pair of themeProperties(theme)) {
        el.style.setProperty(pair[0], pair[1]);
        names.push(pair[0]);
      }
    }
    appliedNames.set(el, names);
    el.setAttribute("data-wmux-theme", theme.source);
    el.setAttribute("data-wmux-scheme", theme.scheme);
    setFlag(el, "data-wmux-high-contrast", theme.highContrast);
    setFlag(el, "data-wmux-reduced-motion", theme.reducedMotion);
  }
  currentNormalized = theme;
  for (const fn of Array.from(listeners)) {
    try {
      fn(theme);
    } catch (err) {
      console.error("[wmux-theme] listener threw", err);
    }
  }
  if (typeof document !== "undefined" && typeof CustomEvent === "function") {
    document.dispatchEvent(new CustomEvent("wmux:themechange", { detail: theme }));
  }
  return theme;
}

function setFlag(el, name, on) {
  if (on) el.setAttribute(name, "true");
  else el.removeAttribute(name);
}

/** The last applied (normalized) theme, or null before the first one. */
export function currentTheme() {
  return currentNormalized;
}

/**
 * Run `fn(theme)` after every applied theme.
 * @returns {() => void} unsubscribe
 */
export function onThemeChange(fn) {
  if (typeof fn !== "function") throw new TypeError("listener must be a function");
  listeners.add(fn);
  return () => listeners.delete(fn);
}

let installed = false;

/** Wire bridge theme messages to the page. Runs automatically on import; idempotent. */
export function installTheme() {
  if (installed) return;
  installed = true;

  wmux.on("panel.init", (ctx) => {
    if (ctx && ctx.theme && typeof ctx.theme === "object") applyTheme(ctx.theme);
    else if (!currentNormalized || currentNormalized.source !== "host") applyTheme(null);
  });
  wmux.on("theme", (payload) => {
    if (payload && typeof payload === "object") applyTheme(payload);
  });

  if (typeof document === "undefined") return;
  if (wmux.theme) applyTheme(wmux.theme);
  else if (!wmux.available) applyTheme(null);

  // Default mode follows the profile's color scheme until a host theme arrives.
  if (typeof matchMedia === "function") {
    const query = matchMedia("(prefers-color-scheme: light)");
    const onChange = () => {
      if (currentNormalized && currentNormalized.source === "default") applyTheme(null);
    };
    if (typeof query.addEventListener === "function") query.addEventListener("change", onChange);
  }
}

installTheme();
