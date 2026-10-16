/**
 * Diff viewer display preferences (pure). The page persists them globally
 * through the `viewerPrefs.set` bridge method; native seeds new viewers with
 * the stored values (README "Preferences").
 *
 * cmux keys: layout, diffIndicators, wordWrap, wordDiffs, lineNumbers,
 * showBackgrounds, expandUnchanged. wmux adds ignoreWhitespace and
 * contextLines. Unknown keys and invalid values are dropped.
 */

export const LAYOUTS = Object.freeze(["unified", "split"]);
export const INDICATORS = Object.freeze(["bars", "classic", "none"]);
export const BOOLEAN_KEYS = Object.freeze([
  "wordWrap",
  "wordDiffs",
  "lineNumbers",
  "showBackgrounds",
  "expandUnchanged",
  "ignoreWhitespace",
]);
export const CONTEXT_LINES = Object.freeze({ min: 0, max: 100, default: 3 });
/** Default font size in pt (cmux `--font-size` default). */
export const DEFAULT_FONT_SIZE_PT = 10;
export const FONT_SIZE_PT = Object.freeze({ min: 6, max: 72 });

export const BUILTIN_PREFS = Object.freeze({
  layout: "unified",
  diffIndicators: "bars",
  wordWrap: false,
  wordDiffs: true,
  lineNumbers: true,
  showBackgrounds: true,
  expandUnchanged: false,
  ignoreWhitespace: false,
  contextLines: CONTEXT_LINES.default,
});

/** Keep only known keys with valid values. */
export function sanitizePrefs(raw) {
  const out = {};
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return out;
  if (LAYOUTS.includes(raw.layout)) out.layout = raw.layout;
  if (INDICATORS.includes(raw.diffIndicators)) out.diffIndicators = raw.diffIndicators;
  for (const k of BOOLEAN_KEYS) if (typeof raw[k] === "boolean") out[k] = raw[k];
  const c = raw.contextLines;
  if (typeof c === "number" && Number.isInteger(c) && c >= CONTEXT_LINES.min && c <= CONTEXT_LINES.max) {
    out.contextLines = c;
  }
  return out;
}

function settingValue(settings, dotted) {
  if (!settings || typeof settings !== "object") return undefined;
  if (settings[dotted] !== undefined) return settings[dotted];
  const [group, key] = dotted.split(".");
  const g = settings[group];
  return g && typeof g === "object" ? g[key] : undefined;
}

/**
 * Effective preferences for a new viewer.
 * Layout precedence: explicit `params.layout` (--layout) > persisted prefs >
 * `diffViewer.defaultLayout` setting > "unified". A restored viewer's own
 * saved prefs (`state.prefs`) win over all of them.
 * @param {{params?: object, prefs?: object, settings?: object, state?: object}} src
 */
export function resolvePrefs(src) {
  const s = src || {};
  const persisted = sanitizePrefs(s.prefs);
  const out = { ...BUILTIN_PREFS };
  const defLayout = settingValue(s.settings, "diffViewer.defaultLayout");
  if (LAYOUTS.includes(defLayout)) out.layout = defLayout;
  Object.assign(out, persisted);
  const explicit = s.params && s.params.layout;
  if (LAYOUTS.includes(explicit)) out.layout = explicit;
  // A restored viewer keeps the choices made in it before the restart.
  Object.assign(out, sanitizePrefs(s.state && s.state.prefs));
  return out;
}

/** Font size in pt: `params.font_size` when valid, else 10. */
export function resolveFontSize(params) {
  const v = params && Number(params.font_size);
  if (Number.isFinite(v) && v >= FONT_SIZE_PT.min && v <= FONT_SIZE_PT.max) return v;
  return DEFAULT_FONT_SIZE_PT;
}

/** CSS px for a pt size (96 / 72). */
export function ptToPx(pt) {
  return Math.round(((pt * 96) / 72) * 100) / 100;
}
