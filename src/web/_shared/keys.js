/**
 * Keyboard integration for wmux web panels (ARCHITECTURE ADR-6.8, ADR-8).
 *
 * Native runs the KeyRouter first for every key WebView2 reports through
 * ICoreWebView2Controller::AcceleratorKeyPressed and marks consumed keys
 * handled, so the page never sees them. WebView2 only reports *accelerators*:
 * keys pressed with Ctrl or Alt, keys that produce no character (F-keys,
 * arrows, Home/End, PgUp/PgDn, Insert, Delete) and Escape. Everything else
 * reaches only the page: bare or Shift-only printable keys, Enter, Tab,
 * Space, Backspace, and the mouse X buttons. This module is the page side:
 *
 *  1. Bare-key panel shortcuts. Native sends the effective bindings for this
 *     panel in panel.init.keymap ({"<action id>": ["j", "g g", ...]}). The page
 *     registers handlers for the actions it implements:
 *
 *       import { installKeys } from "../_shared/keys.js";
 *       const keys = installKeys();
 *       keys.handle("diffViewerScrollDown", () => scrollBy(0, 40));
 *
 *  2. Forwarding. A bound key with no page handler that native could not see
 *     (see above) is forwarded to the KeyRouter with
 *     panel.forward_key {strokes: ["q"], sequence: false}. Native matches the
 *     strokes in this panel's context and runs the action.
 *
 *  3. Chords. Two-stroke bindings whose strokes reach the page ("g g", "] f")
 *     are tracked here (1.5 s window, Escape cancels). When native consumed a
 *     chord prefix itself (e.g. Ctrl+B of "ctrl+b c"), it sends the event
 *     panel.key_sequence {active: true, timeout_ms}; the next non-accelerator
 *     key is then forwarded with sequence: true. {active: false} ends it.
 *
 *  4. Key capture. startCapture() sends panel.key_capture {on: true} so the
 *     KeyRouter skips this panel (shortcut recorders); the returned release
 *     function turns it off again (also on pagehide).
 *
 * Text always wins: in text fields only Ctrl/Alt/Win combinations, Escape and
 * F-keys can match (typing and caret keys stay with the field), and AltGr or
 * Ctrl+Alt combinations that produce a character are text.
 * Strokes use the ADR-8.3 grammar: modifiers ctrl/shift/alt/win joined with
 * "+", letters by virtual key, digits and punctuation by US key position.
 */
import { wmux } from "./wmux-bridge.js";

/** Chord window (ADR-8.2). */
export const CHORD_TIMEOUT_MS = 1500;

const MODIFIER_ORDER = ["ctrl", "shift", "alt", "win"];
const MODIFIER_ALIASES = {
  ctrl: "ctrl",
  control: "ctrl",
  ctl: "ctrl",
  shift: "shift",
  alt: "alt",
  opt: "alt",
  option: "alt",
  win: "win",
  super: "win",
};
const NAMED_KEYS = new Set([
  "enter",
  "tab",
  "space",
  "escape",
  "backspace",
  "delete",
  "insert",
  "home",
  "end",
  "pgup",
  "pgdn",
  "up",
  "down",
  "left",
  "right",
  "mouse4",
  "mouse5",
]);
const PUNCTUATION = new Set([",", ".", "/", ";", "'", "[", "]", "\\", "-", "=", "`"]);
/** Shifted US-layout characters, accepted in bindings as shift+<base key>. */
const SHIFTED = {
  "!": "1",
  "@": "2",
  "#": "3",
  $: "4",
  "%": "5",
  "^": "6",
  "&": "7",
  "*": "8",
  "(": "9",
  ")": "0",
  _: "-",
  "+": "=",
  "{": "[",
  "}": "]",
  "|": "\\",
  ":": ";",
  '"': "'",
  "<": ",",
  ">": ".",
  "?": "/",
  "~": "`",
};
const WORD_ALIASES = {
  return: "enter",
  esc: "escape",
  del: "delete",
  ins: "insert",
  pageup: "pgup",
  pagedown: "pgdn",
  arrowup: "up",
  arrowdown: "down",
  arrowleft: "left",
  arrowright: "right",
  comma: ",",
  period: ".",
  slash: "/",
  semicolon: ";",
  quote: "'",
  apostrophe: "'",
  bracketleft: "[",
  bracketright: "]",
  backslash: "\\",
  minus: "-",
  equal: "=",
  equals: "=",
  backquote: "`",
  grave: "`",
};
const UNBIND_VALUES = new Set(["", "none", "clear", "unbound", "disabled"]);

/** DOM KeyboardEvent.key values -> grammar key names. */
const DOM_NAMED_KEYS = {
  Enter: "enter",
  Tab: "tab",
  " ": "space",
  Spacebar: "space",
  Escape: "escape",
  Esc: "escape",
  Backspace: "backspace",
  Delete: "delete",
  Del: "delete",
  Insert: "insert",
  Home: "home",
  End: "end",
  PageUp: "pgup",
  PageDown: "pgdn",
  ArrowUp: "up",
  ArrowDown: "down",
  ArrowLeft: "left",
  ArrowRight: "right",
  Up: "up",
  Down: "down",
  Left: "left",
  Right: "right",
};
/** DOM KeyboardEvent.code (physical US position) -> digit or punctuation key. */
const DOM_CODE_KEYS = {
  Digit0: "0",
  Digit1: "1",
  Digit2: "2",
  Digit3: "3",
  Digit4: "4",
  Digit5: "5",
  Digit6: "6",
  Digit7: "7",
  Digit8: "8",
  Digit9: "9",
  Minus: "-",
  Equal: "=",
  BracketLeft: "[",
  BracketRight: "]",
  Backslash: "\\",
  Semicolon: ";",
  Quote: "'",
  Comma: ",",
  Period: ".",
  Slash: "/",
  Backquote: "`",
};
const DOM_IGNORED_KEYS = new Set([
  "Alt",
  "AltGraph",
  "CapsLock",
  "Control",
  "Dead",
  "Fn",
  "FnLock",
  "Hyper",
  "Meta",
  "NumLock",
  "OS",
  "Process",
  "ScrollLock",
  "Shift",
  "Super",
  "Symbol",
  "SymbolLock",
  "Unidentified",
]);
const NON_TEXT_INPUT_TYPES = new Set([
  "button",
  "checkbox",
  "color",
  "file",
  "hidden",
  "image",
  "radio",
  "range",
  "reset",
  "submit",
]);
const TEXT_ROLES = new Set(["textbox", "searchbox", "combobox", "spinbutton"]);
const ACTIVATION_TAGS = new Set(["A", "BUTTON", "SUMMARY", "SELECT", "INPUT", "TEXTAREA"]);
const ACTIVATION_ROLES = new Set([
  "button",
  "link",
  "checkbox",
  "radio",
  "switch",
  "menuitem",
  "menuitemcheckbox",
  "menuitemradio",
  "option",
  "tab",
  "treeitem",
]);
const NO_FORWARD_CODES = new Set(["method_not_found", "forbidden", "not_supported"]);
const EMPTY_MAP = new Map();

function resolveKeyToken(token, stroke) {
  if (/^[a-z0-9]$/.test(token) || PUNCTUATION.has(token)) return token;
  if (NAMED_KEYS.has(token) || /^f([1-9]|1[0-9]|2[0-4])$/.test(token)) return token;
  if (Object.prototype.hasOwnProperty.call(SHIFTED, token)) {
    stroke.shift = true;
    return SHIFTED[token];
  }
  if (token === "plus") {
    stroke.shift = true;
    return "=";
  }
  if (Object.prototype.hasOwnProperty.call(WORD_ALIASES, token)) return WORD_ALIASES[token];
  return null;
}

/**
 * Parse one stroke ("ctrl+shift+p", "Shift+G", "]", "f5") into
 * {ctrl, shift, alt, win, key}, or null when invalid ("cmd" is rejected).
 *
 * @param {string} text
 */
export function parseStroke(text) {
  if (typeof text !== "string") return null;
  const raw = text.trim().toLowerCase();
  if (raw === "") return null;
  let parts;
  if (raw === "+") parts = ["+"];
  else if (raw.endsWith("++")) parts = raw.slice(0, -2).split("+").concat("+");
  else parts = raw.split("+");

  const stroke = { ctrl: false, shift: false, alt: false, win: false, key: "" };
  for (let i = 0; i < parts.length - 1; i += 1) {
    const modifier = MODIFIER_ALIASES[parts[i].trim()];
    if (!modifier || stroke[modifier]) return null;
    stroke[modifier] = true;
  }
  const key = resolveKeyToken(parts[parts.length - 1].trim(), stroke);
  if (!key) return null;
  stroke.key = key;
  return stroke;
}

/** Canonical text of a stroke: modifiers in ctrl, shift, alt, win order, then the key. */
export function formatStroke(stroke) {
  const parts = [];
  for (const modifier of MODIFIER_ORDER) if (stroke[modifier]) parts.push(modifier);
  parts.push(stroke.key);
  return parts.join("+");
}

/**
 * Parse a binding: one stroke, a chord "ctrl+b c" (space separated) or a chord
 * array ["ctrl+b", "c"]. Returns canonical strokes (1 or 2), or null for invalid
 * and unbind values (null, "", "none", "clear", "unbound", "disabled").
 *
 * @param {string|string[]} value
 * @returns {string[]|null}
 */
export function parseBinding(value) {
  let parts;
  if (Array.isArray(value)) {
    parts = value;
  } else if (typeof value === "string") {
    const text = value.trim();
    if (UNBIND_VALUES.has(text.toLowerCase())) return null;
    parts = text.split(/\s+/);
  } else {
    return null;
  }
  if (parts.length < 1 || parts.length > 2) return null;
  const strokes = [];
  for (const part of parts) {
    const stroke = parseStroke(part);
    if (!stroke) return null;
    strokes.push(formatStroke(stroke));
  }
  return strokes;
}

/**
 * Normalize panel.init.keymap into [{action, strokes}]. Accepted shapes:
 *   {"<action id>": "j"}                       one binding
 *   {"<action id>": ["j", "down", "g g"]}      alternatives (nested arrays are chords)
 *   {"<action id>": {"keys": [...]}}           object form
 *   [{"action": "<id>", "keys": [...]}]        list form
 * Invalid bindings are dropped.
 */
export function normalizeKeymap(raw) {
  const out = [];
  const addOne = (action, binding) => {
    const strokes = parseBinding(binding);
    if (strokes) out.push({ action, strokes });
  };
  const addAll = (action, value) => {
    if (typeof action !== "string" || action.trim() === "") return;
    const id = action.trim();
    if (typeof value === "string") {
      addOne(id, value);
    } else if (Array.isArray(value)) {
      for (const binding of value) addOne(id, binding);
    } else if (value && typeof value === "object") {
      addAll(id, value.keys !== undefined ? value.keys : value.key);
    }
  };
  if (Array.isArray(raw)) {
    for (const entry of raw) {
      if (entry && typeof entry === "object") {
        addAll(entry.action || entry.id, entry.keys !== undefined ? entry.keys : entry.key);
      }
    }
  } else if (raw && typeof raw === "object") {
    for (const action of Object.keys(raw)) addAll(action, raw[action]);
  }
  return out;
}

function buildIndex(bindings) {
  const singles = new Map();
  const chords = new Map();
  const add = (map, key, action) => {
    const list = map.get(key);
    if (list) {
      if (list.indexOf(action) < 0) list.push(action);
    } else {
      map.set(key, [action]);
    }
  };
  for (const binding of bindings) {
    if (binding.strokes.length === 1) {
      add(singles, binding.strokes[0], binding.action);
    } else {
      let seconds = chords.get(binding.strokes[0]);
      if (!seconds) {
        seconds = new Map();
        chords.set(binding.strokes[0], seconds);
      }
      add(seconds, binding.strokes[1], binding.action);
    }
  }
  return { bindings, singles, chords };
}

function keyFromEvent(e) {
  const key = typeof e.key === "string" ? e.key : "";
  if (DOM_IGNORED_KEYS.has(key)) return null;
  if (Object.prototype.hasOwnProperty.call(DOM_NAMED_KEYS, key)) return DOM_NAMED_KEYS[key];
  if (e.code === "NumpadEnter") return "enter";
  if (/^F([1-9]|1[0-9]|2[0-4])$/.test(key)) return key.toLowerCase();
  // Letters by virtual key (keyCode is the Windows VK in WebView2).
  if (e.keyCode >= 65 && e.keyCode <= 90) return String.fromCharCode(e.keyCode + 32);
  // Digits and punctuation by physical position.
  if (Object.prototype.hasOwnProperty.call(DOM_CODE_KEYS, e.code)) return DOM_CODE_KEYS[e.code];
  return null;
}

/**
 * Canonical stroke for a keydown event, or null for modifier-only keys, dead
 * keys, IME composition and AltGr text.
 *
 * @param {KeyboardEvent} e
 */
export function strokeFromKeyboardEvent(e) {
  if (!e || e.isComposing || e.keyCode === 229) return null;
  const key = keyFromEvent(e);
  if (!key) return null;
  if (typeof e.key === "string" && e.key.length === 1) {
    // AltGr (or Ctrl+Alt) that produced text is typing: text always wins (ADR-8.2).
    const altGraph = typeof e.getModifierState === "function" && e.getModifierState("AltGraph");
    if (altGraph) return null;
    if (e.ctrlKey && e.altKey) {
      const nonAscii = e.key.charCodeAt(0) > 0x7e;
      const changed = !e.shiftKey && e.key.toLowerCase() !== key;
      if (nonAscii || changed) return null;
    }
  }
  return formatStroke({
    ctrl: Boolean(e.ctrlKey),
    shift: Boolean(e.shiftKey),
    alt: Boolean(e.altKey),
    win: Boolean(e.metaKey),
    key,
  });
}

/**
 * Whether WebView2 reports this keydown to native through AcceleratorKeyPressed
 * (native has already offered it to the KeyRouter when the page sees it).
 *
 * @param {KeyboardEvent} e
 */
export function isHostAccelerator(e) {
  if (e.ctrlKey || e.altKey || e.metaKey) return true;
  const key = e.key;
  if (key === "Escape" || key === "Esc") return true;
  if (key === "Enter" || key === "Tab" || key === "Backspace") return false;
  if (key === " " || key === "Spacebar") return false;
  if (typeof key === "string" && key.length === 1) return false;
  return true;
}

function eventTarget(e) {
  const path = typeof e.composedPath === "function" ? e.composedPath() : null;
  const target = path && path.length > 0 ? path[0] : e.target;
  return target && target.nodeType === 1 ? target : null;
}

/**
 * Whether a stroke may match while a text field has focus. Fields own typing
 * and caret keys (letters, digits, Enter, Tab, Space, Backspace, Delete,
 * arrows, Home/End, PgUp/PgDn, with or without Shift); only Ctrl, Alt or Win
 * combinations, Escape and F-keys can be shortcuts there.
 *
 * @param {string} stroke canonical stroke
 */
export function isTextFieldShortcut(stroke) {
  const parts = String(stroke).split("+");
  const key = parts[parts.length - 1];
  if (key === "escape" || /^f([1-9]|1[0-9]|2[0-4])$/.test(key)) return true;
  return parts.slice(0, -1).some((m) => m === "ctrl" || m === "alt" || m === "win");
}

/** Whether the event targets a text-entry control (inputs, textareas, contenteditable). */
export function isTextEntryTarget(e) {
  const t = eventTarget(e);
  if (!t) return false;
  if (t.isContentEditable) return true;
  if (t.tagName === "TEXTAREA" || t.tagName === "SELECT") return true;
  if (t.tagName === "INPUT") {
    return !NON_TEXT_INPUT_TYPES.has(String(t.type || "text").toLowerCase());
  }
  const role = typeof t.getAttribute === "function" ? t.getAttribute("role") : null;
  return role !== null && TEXT_ROLES.has(role);
}

function isActivationTarget(e) {
  const t = eventTarget(e);
  if (!t) return false;
  if (ACTIVATION_TAGS.has(t.tagName)) return true;
  const role = typeof t.getAttribute === "function" ? t.getAttribute("role") : null;
  return role !== null && ACTIVATION_ROLES.has(role);
}

function consume(e) {
  e.preventDefault();
  e.stopPropagation();
}

let controller = null;

/**
 * Install the page keyboard layer (once per page; later calls return the same
 * controller and merge `options`).
 *
 * @param {{handlers?: Record<string, Function>, keymap?: unknown}} [options]
 *   handlers: action id -> handler({action, strokes, event})
 *   keymap: initial keymap; panel.init.keymap and "keymap" events replace it
 */
export function installKeys(options) {
  if (!controller) controller = createController();
  const opts = options || {};
  if (opts.handlers) {
    for (const action of Object.keys(opts.handlers)) controller.handle(action, opts.handlers[action]);
  }
  if (opts.keymap !== undefined) controller.setKeymap(opts.keymap);
  return controller;
}

function createController() {
  const handlers = new Map();
  const unsubscribers = [];
  let index = buildIndex([]);
  let localPending = null;
  let hostPending = null;
  let captureDepth = 0;
  let captureEpoch = 0; // bumped when pagehide drops every capture
  let forwarding = true;

  function setKeymap(raw) {
    index = buildIndex(normalizeKeymap(raw));
    clearLocalPending();
  }

  function handle(action, fn) {
    if (typeof action !== "string" || action === "") throw new TypeError("action id required");
    if (typeof fn !== "function") throw new TypeError("handler must be a function");
    handlers.set(action, fn);
    return () => {
      if (handlers.get(action) === fn) handlers.delete(action);
    };
  }

  function bindingsFor(action) {
    return index.bindings
      .filter((binding) => binding.action === action)
      .map((binding) => binding.strokes.join(" "));
  }

  function canForward() {
    return forwarding && wmux.available;
  }

  function forward(strokes, sequence) {
    wmux.call("panel.forward_key", { strokes, sequence }).catch((err) => {
      if (err && NO_FORWARD_CODES.has(err.code) && forwarding) {
        forwarding = false;
        console.warn("[wmux-keys] the host does not accept panel.forward_key (" + err.code + ")");
      }
    });
  }

  /**
   * Run the page handler of the first action that has one, else forward the
   * strokes when native could not have seen all of them.
   */
  function run(actions, strokes, event, hostSawAll) {
    for (const action of actions) {
      const fn = handlers.get(action);
      if (fn) {
        consume(event);
        try {
          fn({ action, strokes: strokes.slice(), event });
        } catch (err) {
          console.error('[wmux-keys] handler for "' + action + '" threw', err);
        }
        return true;
      }
    }
    if (hostSawAll || !canForward()) return false;
    consume(event);
    forward(strokes, false);
    return true;
  }

  /** A prefix only waits for a second stroke if some chord behind it can run. */
  function chordActionable(prefix) {
    const seconds = index.chords.get(prefix);
    if (!seconds) return false;
    if (canForward()) return true;
    for (const actions of seconds.values()) {
      for (const action of actions) if (handlers.has(action)) return true;
    }
    return false;
  }

  function clearLocalPending() {
    if (localPending) clearTimeout(localPending.timer);
    localPending = null;
  }

  function clearHostPending() {
    if (hostPending) clearTimeout(hostPending.timer);
    hostPending = null;
  }

  function startHostPending(timeoutMs) {
    clearHostPending();
    clearLocalPending();
    const ms = Math.min(Math.max(Number(timeoutMs) || CHORD_TIMEOUT_MS, 100), 10000);
    hostPending = { timer: setTimeout(clearHostPending, ms + 250) };
  }

  function onKeyDown(e) {
    if (captureDepth > 0) return;
    const stroke = strokeFromKeyboardEvent(e);
    if (!stroke) return;
    const accel = isHostAccelerator(e);

    // Second stroke of a chord whose prefix native consumed.
    if (hostPending) {
      if (accel) return; // native sees accelerators itself and ends the sequence
      clearHostPending();
      if (canForward()) {
        consume(e);
        forward([stroke], true);
      }
      return;
    }

    // Second stroke of a chord tracked here.
    if (localPending) {
      consume(e); // the stroke after a prefix never types or triggers page defaults
      if (e.repeat) return; // holding the prefix key does not complete "g g"
      const first = localPending;
      clearLocalPending();
      if (stroke === "escape") return;
      const actions = (index.chords.get(first.stroke) || EMPTY_MAP).get(stroke);
      if (actions) run(actions, [first.stroke, stroke], e, first.accel && accel);
      return;
    }

    // Text always wins in text fields (typing and caret keys stay with the
    // field); Enter and Space keep activating controls.
    if (isTextEntryTarget(e) && !isTextFieldShortcut(stroke)) return;
    const key = stroke.slice(stroke.lastIndexOf("+") + 1);
    if (!accel && (key === "enter" || key === "space") && isActivationTarget(e)) return;

    if (!e.repeat && chordActionable(stroke)) {
      consume(e);
      localPending = {
        stroke,
        accel,
        timer: setTimeout(clearLocalPending, CHORD_TIMEOUT_MS),
      };
      return;
    }

    const actions = index.singles.get(stroke);
    if (actions) run(actions, [stroke], e, accel);
  }

  function onMouseUp(e) {
    if (captureDepth > 0) return;
    const key = e.button === 3 ? "mouse4" : e.button === 4 ? "mouse5" : null;
    if (!key) return;
    const stroke = formatStroke({
      ctrl: Boolean(e.ctrlKey),
      shift: Boolean(e.shiftKey),
      alt: Boolean(e.altKey),
      win: Boolean(e.metaKey),
      key,
    });
    const actions = index.singles.get(stroke);
    // Native never sees mouse buttons inside the page.
    if (actions) run(actions, [stroke], e, false);
  }

  function setHostCapture(on) {
    if (!wmux.available) return;
    wmux.panel.keyCapture(on).catch((err) => {
      console.warn("[wmux-keys] panel.key_capture failed:", err && err.code);
    });
  }

  /**
   * Ask the KeyRouter to skip this panel (shortcut recorders) and disable this
   * layer until every returned release function has been called.
   * @returns {() => void} release
   */
  function startCapture() {
    captureDepth += 1;
    clearLocalPending();
    clearHostPending();
    if (captureDepth === 1) setHostCapture(true);
    const epoch = captureEpoch;
    let released = false;
    return () => {
      if (released) return;
      released = true;
      // A capture dropped by pagehide is already released.
      if (epoch !== captureEpoch) return;
      captureDepth -= 1;
      if (captureDepth === 0) setHostCapture(false);
    };
  }

  function onPageHide() {
    clearLocalPending();
    clearHostPending();
    if (captureDepth > 0) {
      captureDepth = 0;
      captureEpoch += 1;
      wmux.send("panel.key_capture", { on: false });
    }
  }

  function onBlur() {
    clearLocalPending();
    clearHostPending();
  }

  unsubscribers.push(
    wmux.on("panel.init", (ctx) => {
      if (ctx && ctx.keymap !== undefined) setKeymap(ctx.keymap);
    }),
    wmux.on("keymap", (payload) => setKeymap(payload)),
    wmux.on("panel.key_sequence", (payload) => {
      if (payload && payload.active) startHostPending(payload.timeout_ms);
      else clearHostPending();
    }),
  );
  if (wmux.context && wmux.context.keymap !== undefined) setKeymap(wmux.context.keymap);

  const win = typeof window !== "undefined" ? window : null;
  if (win && typeof win.addEventListener === "function") {
    win.addEventListener("keydown", onKeyDown, true);
    win.addEventListener("mouseup", onMouseUp, true);
    win.addEventListener("focusin", clearLocalPending, true);
    win.addEventListener("pagehide", onPageHide);
    win.addEventListener("blur", onBlur);
  }

  function dispose() {
    onPageHide();
    for (const off of unsubscribers) off();
    if (win && typeof win.removeEventListener === "function") {
      win.removeEventListener("keydown", onKeyDown, true);
      win.removeEventListener("mouseup", onMouseUp, true);
      win.removeEventListener("focusin", clearLocalPending, true);
      win.removeEventListener("pagehide", onPageHide);
      win.removeEventListener("blur", onBlur);
    }
    handlers.clear();
    if (controller === api) controller = null;
  }

  const api = Object.freeze({
    /** Register the page handler for an action id; returns an unregister function. */
    handle,
    /** Replace the keymap (same shapes as panel.init.keymap). */
    setKeymap,
    /** Bindings of an action as display strings ("ctrl+d", "g g"), e.g. for hints. */
    bindingsFor,
    startCapture,
    /** Remove all listeners (mainly for tests); installKeys() creates a new layer. */
    dispose,
    get capturing() {
      return captureDepth > 0;
    },
    get forwarding() {
      return canForward();
    },
  });
  return api;
}
