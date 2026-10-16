/**
 * Typography settings of the markdown panel (pure functions).
 *
 * Settings (cmux.json / wmux.json `markdown.*`, pushed by native in
 * panel.init.settings and panel.markdown.settings):
 *   markdown.fontSize    pt, default 15, 8..96 step 1; applied as zoom = size / 15
 *   markdown.fontFamily  "" = the system (GitHub) stack; code stays monospace
 *   markdown.maxWidth    CSS px, default 980, 320..2400 step 20 (reading column)
 * Each viewer keeps its own values. When the defaults change, a viewer adopts
 * the new default for every value it had not customized (value == old default).
 */

export const BUILTIN_DEFAULTS = Object.freeze({ fontSize: 15, fontFamily: "", maxWidth: 980 });

export const LIMITS = Object.freeze({
  fontSize: Object.freeze({ min: 8, max: 96, step: 1 }),
  maxWidth: Object.freeze({ min: 320, max: 2400, step: 20 }),
});

/** Font size at which the zoom factor is 1. */
export const BASE_FONT_SIZE = 15;

const MAX_FAMILY_LENGTH = 128;

function clampStep(value, limits, fallback) {
  const n = typeof value === "string" && value.trim() !== "" ? Number(value) : value;
  if (typeof n !== "number" || !isFinite(n)) return fallback;
  const stepped = Math.round((n - limits.min) / limits.step) * limits.step + limits.min;
  return Math.min(limits.max, Math.max(limits.min, stepped));
}

/** Font size in pt clamped to 8..96, whole points. */
export function clampFontSize(value, fallback = BUILTIN_DEFAULTS.fontSize) {
  return clampStep(value, LIMITS.fontSize, fallback);
}

/** Reading column width clamped to 320..2400, steps of 20. */
export function clampMaxWidth(value, fallback = BUILTIN_DEFAULTS.maxWidth) {
  return clampStep(value, LIMITS.maxWidth, fallback);
}

/** A font family name without control characters or quotes, "" for the system stack. */
export function normalizeFontFamily(value) {
  if (typeof value !== "string") return "";
  const text = value.replace(/[\u0000-\u001f\u007f"'\\;{}<>]/g, "").trim();
  if (text.toLowerCase() === "system") return "";
  return text.slice(0, MAX_FAMILY_LENGTH);
}

/** Complete, clamped typography values; missing keys come from `fallback`. */
export function normalizeTypography(raw, fallback = BUILTIN_DEFAULTS) {
  const src = raw && typeof raw === "object" ? raw : {};
  return {
    fontSize: clampFontSize(src.fontSize, fallback.fontSize),
    fontFamily: src.fontFamily === undefined ? fallback.fontFamily : normalizeFontFamily(src.fontFamily),
    maxWidth: clampMaxWidth(src.maxWidth, fallback.maxWidth),
  };
}

/**
 * Read the markdown defaults from a settings object. Accepted shapes:
 * {"markdown.fontSize": 15}, {markdown: {fontSize: 15}}, {fontSize: 15}
 * (camelCase or snake_case keys).
 */
export function readDefaults(settings) {
  const src = settings && typeof settings === "object" ? settings : {};
  const nested = src.markdown && typeof src.markdown === "object" ? src.markdown : {};
  const pick = (name, snake) => {
    for (const value of [
      src["markdown." + name],
      nested[name],
      nested[snake],
      src[name],
      src[snake],
    ]) {
      if (value !== undefined && value !== null) return value;
    }
    return undefined;
  };
  return normalizeTypography({
    fontSize: pick("fontSize", "font_size"),
    fontFamily: pick("fontFamily", "font_family"),
    maxWidth: pick("maxWidth", "max_width"),
  });
}

/** Page zoom for a font size (size / 15). */
export function zoomFactor(fontSize) {
  return Math.round((clampFontSize(fontSize) / BASE_FONT_SIZE) * 10000) / 10000;
}

/** Values after a defaults change: untouched values follow, customized ones stay. */
export function adoptDefaults(current, previousDefaults, nextDefaults) {
  const out = {};
  for (const key of Object.keys(BUILTIN_DEFAULTS)) {
    out[key] = current[key] === previousDefaults[key] ? nextDefaults[key] : current[key];
  }
  return out;
}

/** One zoom step (+1 / -1 pt), clamped. */
export function zoomStep(current, delta) {
  return clampFontSize(clampFontSize(current) + delta);
}

/** CSS font-family value for a family name ("" -> null: use the stylesheet's stack). */
export function fontFamilyCss(family) {
  const name = normalizeFontFamily(family);
  if (name === "") return null;
  return '"' + name + '", var(--mdv-font-stack)';
}

/** Same values? */
export function sameTypography(a, b) {
  return a.fontSize === b.fontSize && a.fontFamily === b.fontFamily && a.maxWidth === b.maxWidth;
}
