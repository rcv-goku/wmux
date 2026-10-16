/**
 * Keyboard shortcuts editor logic (pure; ADR-8.3, ADR-8.6). Normalizes the
 * `wmux.shortcuts.list` reply, formats strokes for display, validates a
 * recorded shortcut (modifier rule, numbered actions, Windows-reserved keys,
 * conflicts) and filters the list. Native validates again with
 * `wmux.shortcuts.validate` (strokes.zig); its verdict wins.
 */
import { formatStroke, parseBinding, parseStroke } from "../_shared/keys.js";
import { foldText, queryTokens } from "./schema.js";
import { t } from "./strings.js";

/** Category order (actions_catalog.zig `Category`). */
export const CATEGORIES = Object.freeze([
  "app",
  "window",
  "workspace",
  "surface",
  "pane",
  "notification",
  "browser",
  "find",
  "viewer",
  "sidebar",
  "canvas",
  "agent",
  "terminal",
]);

/** Presets offered when native sends none (keymap_presets.zig names). */
export const FALLBACK_PRESETS = Object.freeze([
  { name: "cmux", title: "wmux (Default)", description: "", warning: "" },
  { name: "windows-terminal", title: "Windows Terminal", description: "", warning: "" },
  { name: "linux-ghostty", title: "Ghostty (Linux)", description: "", warning: "" },
  { name: "tmux", title: "tmux-style (Ctrl-B prefix)", description: "", warning: "" },
  { name: "wmux-classic", title: "wmux classic", description: "", warning: "" },
]);

/** Strokes Windows keeps for itself: recording them is an error. */
const RESERVED = Object.freeze({
  "alt+tab": "Switch windows",
  "shift+alt+tab": "Switch windows",
  "ctrl+alt+delete": "Security options",
  "ctrl+escape": "Start menu",
  "ctrl+shift+escape": "Task Manager",
  "alt+escape": "Cycle windows",
  "shift+alt+escape": "Cycle windows",
});

/** Strokes Windows may handle first: recording them is a warning. */
const WINDOWS_SHORTCUTS = Object.freeze({
  "alt+space": "Window menu",
  "alt+f4": "Close window",
  "ctrl+alt+tab": "Task switcher",
  "ctrl+shift+alt+delete": "Security options",
  f1: "Help",
});

/** Punctuation keys of the stroke grammar (ADR-8.3); they type text. */
const TEXT_PUNCTUATION = new Set([",", ".", "/", ";", "'", "[", "]", "\\", "-", "=", "`"]);

/** Keys that type text alone or with Shift (strokes.zig `Key.isPrintable`). */
function typesText(key) {
  return /^[a-z0-9]$/.test(key) || key === "space" || TEXT_PUNCTUATION.has(key);
}

/** Built-in when-clause labels; other clauses show "When: <clause>". */
const WHEN_KEYS = Object.freeze([
  "terminalFocus",
  "browserFocus",
  "webPanelFocus",
  "markdownFocus",
  "diffViewerFocus",
  "filePreviewTextEditorFocus",
  "fileExplorerFocus",
  "textBoxFocus",
  "sidebarFocus",
  "rightSidebarFocus",
  "commandPaletteVisible",
  "findVisible",
  "terminalFindVisible",
  "workspaceCanvasLayout",
]);

const KEY_LABELS = Object.freeze({
  pgup: "PgUp",
  pgdn: "PgDn",
  escape: "Esc",
  enter: "Enter",
  tab: "Tab",
  space: "Space",
  backspace: "Backspace",
  delete: "Delete",
  insert: "Insert",
  home: "Home",
  end: "End",
  up: "Up",
  down: "Down",
  left: "Left",
  right: "Right",
  mouse4: "Mouse4",
  mouse5: "Mouse5",
});

const MOD_LABELS = Object.freeze({ ctrl: "Ctrl", shift: "Shift", alt: "Alt", win: "Win" });

/** "ctrl+shift+pgup" -> "Ctrl+Shift+PgUp"; invalid text is returned as-is. */
export function displayStroke(text) {
  const stroke = parseStroke(text);
  if (!stroke) return String(text ?? "");
  const parts = [];
  for (const mod of ["ctrl", "shift", "alt", "win"]) if (stroke[mod]) parts.push(MOD_LABELS[mod]);
  const key = stroke.key;
  if (Object.prototype.hasOwnProperty.call(KEY_LABELS, key)) parts.push(KEY_LABELS[key]);
  else if (/^f\d+$/.test(key)) parts.push(key.toUpperCase());
  else parts.push(key.length === 1 ? key.toUpperCase() : key);
  return parts.join("+");
}

/** Display text of a binding (one stroke or a chord, string or array). */
export function displayBinding(binding) {
  const strokes = parseBinding(binding);
  if (!strokes) return Array.isArray(binding) ? binding.join(" ") : String(binding ?? "");
  return strokes.map(displayStroke).join(" ");
}

/** Canonical text of a binding ("ctrl+b c"), or null when invalid/unbind. */
export function canonicalBinding(binding) {
  const strokes = parseBinding(binding);
  return strokes ? strokes.join(" ") : null;
}

/**
 * Bindings of an action as canonical text. `raw` is one binding (a string)
 * or an array of bindings, where a nested array is a chord (["ctrl+b", "c"]).
 * Unparsable strings are kept as written (shown, never matched); unbind
 * spellings are dropped.
 */
export function keyList(raw) {
  if (raw === null || raw === undefined) return [];
  const list = Array.isArray(raw) ? raw : [raw];
  const out = [];
  for (const item of list) {
    const canonical = canonicalBinding(item);
    if (canonical) {
      if (!out.includes(canonical)) out.push(canonical);
    } else if (
      typeof item === "string" &&
      item.trim() !== "" &&
      !/^(none|clear|unbound|disabled)$/i.test(item.trim())
    ) {
      out.push(item.trim());
    }
  }
  return out;
}

/** Localized "When: …" label for a clause, or "" for global actions. */
export function whenLabel(clause, explicit) {
  if (typeof explicit === "string" && explicit) return explicit;
  if (typeof clause !== "string" || clause.trim() === "") return "";
  const c = clause.trim();
  if (WHEN_KEYS.includes(c)) return t(`settings.shortcuts.when.${c}`);
  return t("settings.shortcuts.when.clause", { clause: c });
}

function normalizeAction(raw) {
  if (!raw || typeof raw !== "object" || typeof raw.id !== "string" || raw.id === "") return null;
  const category = CATEGORIES.includes(raw.category) ? raw.category : "app";
  const source = typeof raw.source === "string" ? raw.source : "default";
  const keys = keyList(raw.keys);
  const hasDefaults =
    Object.prototype.hasOwnProperty.call(raw, "default_keys") ||
    Object.prototype.hasOwnProperty.call(raw, "defaultKeys");
  const defaultKeys = hasDefaults ? keyList(raw.default_keys ?? raw.defaultKeys) : keys.slice();
  const when = typeof raw.when === "string" && raw.when.trim() ? raw.when.trim() : null;
  return {
    id: raw.id,
    title: typeof raw.title === "string" && raw.title ? raw.title : raw.id,
    category,
    keys,
    defaultKeys,
    when,
    whenLabel: whenLabel(when, raw.when_label ?? raw.whenLabel),
    source,
    locked: raw.locked === true || source === "policy",
    managed: raw.locked === true || source === "policy" ? "policy" : source === "cmux.json" ? "cmux.json" : null,
    numbered: raw.numbered === true,
    bareOk: raw.bare_ok === true || raw.bareOk === true || category === "viewer",
    available: raw.availability !== "not_applicable",
  };
}

function normalizePreset(raw) {
  if (!raw || typeof raw !== "object" || typeof raw.name !== "string" || raw.name === "") return null;
  return {
    name: raw.name,
    title: typeof raw.title === "string" && raw.title ? raw.title : raw.name,
    description: typeof raw.description === "string" ? raw.description : "",
    warning: typeof raw.warning === "string" ? raw.warning : "",
  };
}

/**
 * Normalize `wmux.shortcuts.list`: {actions: [...], presets?: [...],
 * preset?: "<name>"} or a bare array of actions. Actions are sorted by
 * category order, then title. Duplicate ids keep the first entry.
 */
export function normalizeShortcutList(result) {
  const rawActions = Array.isArray(result) ? result : result && Array.isArray(result.actions) ? result.actions : [];
  const seen = new Set();
  const actions = [];
  for (const raw of rawActions) {
    const a = normalizeAction(raw);
    if (!a || seen.has(a.id)) continue;
    seen.add(a.id);
    actions.push(a);
  }
  actions.sort(
    (x, y) => CATEGORIES.indexOf(x.category) - CATEGORIES.indexOf(y.category) || x.title.localeCompare(y.title),
  );
  let presets = [];
  if (result && Array.isArray(result.presets)) presets = result.presets.map(normalizePreset).filter(Boolean);
  if (presets.length === 0) presets = FALLBACK_PRESETS.map((p) => ({ ...p }));
  const preset = result && typeof result.preset === "string" ? result.preset : null;
  return { actions, presets, preset };
}

/** True when the two clauses can hold at the same time (conservative). */
export function contextsOverlap(a, b) {
  if (!a || !b) return true;
  return a.replace(/\s+/g, "") === b.replace(/\s+/g, "");
}

/** Whether two canonical bindings collide: equal, or one is the other's chord prefix. */
export function bindingsCollide(a, b) {
  if (a === b) return true;
  const sa = a.split(" ");
  const sb = b.split(" ");
  return sa.length !== sb.length && sa[0] === sb[0];
}

/**
 * The canonical bindings a key stands for. A numbered action's key whose
 * last stroke is a digit covers that digit's whole 1–9 family
 * ("ctrl+shift+1" is ctrl+shift+1…9, "ctrl+b 1" is ctrl+b 1…9), as the
 * KeyRouter and keymap_presets.zig expand it (ADR-8.3); any other key
 * stands for itself.
 */
export function expandNumbered(binding, numbered) {
  if (!numbered) return [binding];
  const strokes = binding.split(" ");
  const last = strokes[strokes.length - 1];
  const plus = last.lastIndexOf("+");
  if (!/^[0-9]$/.test(last.slice(plus + 1))) return [binding];
  const head = strokes.slice(0, -1);
  const mods = last.slice(0, plus + 1);
  const out = [];
  for (let d = 1; d <= 9; d += 1) out.push([...head, `${mods}${d}`].join(" "));
  return out;
}

/**
 * Other actions whose bindings collide with `binding` in an overlapping
 * context. `keys` of each conflict is the colliding binding (for a numbered
 * family, the member that collides, e.g. "ctrl+shift+5").
 */
export function findConflicts(actions, id, binding, when) {
  const canonical = canonicalBinding(binding);
  if (!canonical) return [];
  const self = actions.find((a) => a.id === id);
  const clause = when !== undefined ? when : self ? self.when : null;
  const mine = expandNumbered(canonical, Boolean(self && self.numbered));
  const out = [];
  for (const a of actions) {
    if (a.id === id || !a.available) continue;
    let hit = null;
    for (const k of a.keys) {
      hit = expandNumbered(k, a.numbered).find((x) => mine.some((y) => bindingsCollide(x, y))) || null;
      if (hit) break;
    }
    if (hit && contextsOverlap(clause, a.when)) out.push({ id: a.id, title: a.title, keys: hit });
  }
  return out;
}

/**
 * Validate a recorded binding (canonical strokes, 1 or 2) for an action.
 * Returns {binding, errors: [msg], warnings: [msg], conflicts: [...]};
 * `binding` is the canonical text to save (numbered actions use digit 1).
 */
export function validateBinding(actions, action, strokes) {
  const errors = [];
  const warnings = [];
  const list = Array.isArray(strokes) ? strokes.slice(0, 2) : [strokes];
  const parsed = list.map((s) => parseStroke(s));
  if (parsed.length === 0 || parsed.some((p) => !p)) {
    return { binding: null, errors: [t("settings.shortcuts.invalid")], warnings, conflicts: [] };
  }
  const first = parsed[0];
  const pressed = displayStroke(formatStroke(first)); // before digit normalization
  if (action && action.numbered) {
    const last = parsed[parsed.length - 1];
    if (!/^[1-9]$/.test(last.key)) errors.push(t("settings.shortcuts.digit"));
    else last.key = "1";
  }
  const bareOk = Boolean(action && action.bareOk);
  const hasModifier = first.ctrl || first.alt || first.shift || first.win;
  if (!hasModifier && !/^f\d+$/.test(first.key) && !first.key.startsWith("mouse") && !bareOk) {
    errors.push(t("settings.shortcuts.needsModifier"));
  } else if (first.shift && !first.ctrl && !first.alt && !first.win && typesText(first.key) && !bareOk) {
    // Shift+<text key> types text: the KeyRouter never matches it (ADR-8.2).
    errors.push(t("settings.shortcuts.shiftText", { keys: pressed }));
  }
  const canon = parsed.map(formatStroke);
  for (const s of canon) {
    const p = parseStroke(s);
    if (p.win || Object.prototype.hasOwnProperty.call(RESERVED, s)) {
      errors.push(t("settings.shortcuts.reserved"));
      break;
    }
    if (Object.prototype.hasOwnProperty.call(WINDOWS_SHORTCUTS, s)) {
      warnings.push(t("settings.shortcuts.osShortcut", { keys: displayStroke(s), name: WINDOWS_SHORTCUTS[s] }));
    }
  }
  const binding = canon.join(" ");
  const conflicts = action ? findConflicts(actions, action.id, binding) : [];
  for (const c of conflicts) {
    errors.push(t("settings.shortcuts.conflict", { action: c.title, keys: displayBinding(c.keys) }));
  }
  return { binding, errors, warnings, conflicts };
}

/** Actions matching a search query (title, id, category, when label, keys). */
export function filterActions(actions, query) {
  const tokens = queryTokens(query);
  if (tokens.length === 0) return actions.slice();
  return actions.filter((a) => {
    const hay = foldText(
      [
        a.title,
        a.id,
        t(`settings.shortcuts.category.${a.category}`),
        a.whenLabel,
        ...a.keys,
        ...a.keys.map(displayBinding),
      ].join("\n"),
    );
    return tokens.every((tok) => hay.includes(tok));
  });
}

/** Actions with a binding equal to (or starting with) the detected stroke; numbered families count. */
export function actionsUsingStroke(actions, stroke) {
  const canonical = canonicalBinding(stroke);
  if (!canonical) return [];
  return actions.filter((a) =>
    a.keys.some((k) => expandNumbered(k, a.numbered).some((x) => x === canonical || x.split(" ")[0] === canonical)),
  );
}

/** True when the action's bindings differ from its defaults. */
export function isCustomized(action) {
  if (action.keys.length !== action.defaultKeys.length) return true;
  return action.keys.some((k, i) => k !== action.defaultKeys[i]);
}
