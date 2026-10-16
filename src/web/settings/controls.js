/**
 * Typed form controls for settings rows (DOM). Each builder returns
 * {element, focusTarget, setValue(value), setDisabled(bool)} and reports
 * user edits through `onCommit(value)` (already parsed) or
 * `onError(message)` (unparsable input). Text never goes through innerHTML.
 */
import { strokeFromKeyboardEvent } from "../_shared/keys.js";
import { deepEqual, formatInput, parseInput } from "./schema.js";
import { t } from "./strings.js";

let idCounter = 0;

/** A unique element id with a readable prefix. */
export function uniqueId(prefix) {
  idCounter += 1;
  return `${prefix}-${idCounter}`;
}

function el(doc, tag, props, children) {
  const node = doc.createElement(tag);
  if (props) {
    for (const [key, value] of Object.entries(props)) {
      if (value === undefined || value === null || value === false) continue;
      if (key === "class") node.className = value;
      else if (key === "text") node.textContent = value;
      else if (key in node && typeof value !== "string") node[key] = value;
      else node.setAttribute(key, value === true ? "" : String(value));
    }
  }
  for (const child of children || []) if (child) node.append(child);
  return node;
}

export { el };

/** JSON scalar text -> value for key-value cells; anything else stays a string. */
export function parseCell(text) {
  const trimmed = text.trim();
  if (trimmed === "") return "";
  if (/^(true|false|null|-?\d+(\.\d+)?([eE][+-]?\d+)?)$/.test(trimmed) || /^[[{"]/.test(trimmed)) {
    try {
      return JSON.parse(trimmed);
    } catch {
      return text;
    }
  }
  return text;
}

/** Display text of a key-value cell. */
export function formatCell(value) {
  if (typeof value === "string") {
    // Strings that would read back as another type are shown JSON-quoted.
    return parseCell(value) === value ? value : JSON.stringify(value);
  }
  return JSON.stringify(value);
}

/** True when an object can be edited as flat key -> scalar rows. */
export function isFlatObject(value) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
  return Object.values(value).every((v) => v === null || ["string", "number", "boolean"].includes(typeof v));
}

function boolControl(doc, field, id, onCommit) {
  const input = el(doc, "input", { type: "checkbox", id, role: "switch", class: "set-switch" });
  input.addEventListener("change", () => onCommit(input.checked));
  return {
    element: input,
    focusTarget: input,
    setValue(v) {
      input.checked = v === true;
      input.setAttribute("aria-checked", v === true ? "true" : "false");
    },
    setDisabled(d) {
      input.disabled = d;
    },
  };
}

function enumControl(doc, field, id, onCommit) {
  const select = el(doc, "select", { id, class: "set-select" });
  const values = field.enumValues.slice();
  const fill = (current) => {
    select.replaceChildren();
    let selected = -1;
    values.forEach((v, i) => {
      select.append(el(doc, "option", { value: String(i), text: String(v) }));
      if (JSON.stringify(v) === JSON.stringify(current)) selected = i;
    });
    if (selected < 0) {
      // An out-of-range value from a file: show it, but it cannot be chosen again.
      const label = current === null || current === undefined ? t("settings.null") : JSON.stringify(current);
      select.append(el(doc, "option", { value: "", text: label, disabled: true }));
      select.value = "";
    } else {
      select.value = String(selected);
    }
  };
  select.addEventListener("change", () => {
    const i = Number(select.value);
    if (select.value !== "" && Number.isInteger(i) && i >= 0 && i < values.length) onCommit(values[i]);
  });
  return {
    element: select,
    focusTarget: select,
    setValue: fill,
    setDisabled(d) {
      select.disabled = d;
    },
  };
}

function textControl(doc, field, id, onCommit, onError) {
  const numeric = field.kind === "integer" || field.kind === "number";
  const input = el(doc, "input", {
    id,
    type: numeric ? "number" : "text",
    class: field.kind === "path" ? "set-input wmux-mono" : "set-input",
    spellcheck: "false",
    autocomplete: "off",
  });
  if (numeric) {
    if (field.min !== null) input.min = String(field.min);
    if (field.max !== null) input.max = String(field.max);
    input.step = field.step !== null ? String(field.step) : "any";
    input.inputMode = field.kind === "integer" ? "numeric" : "decimal";
  }
  input.addEventListener("change", () => {
    const parsed = parseInput(field, input.value);
    if (parsed.ok) onCommit(parsed.value);
    else onError(parsed.error);
  });
  return {
    element: input,
    focusTarget: input,
    setValue(v) {
      input.value = numeric ? (typeof v === "number" ? String(v) : "") : formatInput(field, v);
    },
    setDisabled(d) {
      input.disabled = d;
    },
  };
}

function colorControl(doc, field, id, onCommit, onError) {
  // A named group (the row title, via aria-labelledby) gives the swatch and
  // Clear buttons their setting's context; a plain div cannot carry a name.
  const wrap = el(doc, "div", { class: "set-color", role: "group" });
  const swatch = el(doc, "input", {
    type: "color",
    class: "set-color-swatch",
    "aria-label": t("settings.color.picker"),
  });
  const text = el(doc, "input", {
    id,
    type: "text",
    class: "set-input set-color-text wmux-mono",
    spellcheck: "false",
    autocomplete: "off",
  });
  let current = null;
  wrap.append(swatch, text);
  let clear = null;
  if (field.nullable) {
    clear = el(doc, "button", { type: "button", class: "set-small", text: t("settings.color.clear") });
    clear.addEventListener("click", () => onCommit(null));
    wrap.append(clear);
  }
  swatch.addEventListener("change", () => {
    // Keep an alpha suffix the user had (#RRGGBBAA): the swatch has no alpha.
    const alpha = typeof current === "string" && current.length === 9 ? current.slice(7) : "";
    onCommit(swatch.value.toUpperCase() + alpha.toUpperCase());
  });
  text.addEventListener("change", () => {
    const parsed = parseInput(field, text.value);
    if (parsed.ok) onCommit(parsed.value);
    else onError(parsed.error);
  });
  return {
    element: wrap,
    focusTarget: text,
    setValue(v) {
      current = v;
      text.value = typeof v === "string" ? v : "";
      text.placeholder = v === null || v === undefined ? t("settings.null") : "";
      swatch.value = typeof v === "string" && /^#[0-9a-f]{6}/i.test(v) ? v.slice(0, 7).toLowerCase() : "#000000";
    },
    setDisabled(d) {
      swatch.disabled = d;
      text.disabled = d;
      if (clear) clear.disabled = d;
    },
  };
}

function areaControl(doc, field, id, onCommit, onError) {
  const area = el(doc, "textarea", {
    id,
    class: field.kind === "list" ? "set-area" : "set-area wmux-mono",
    spellcheck: "false",
    autocomplete: "off",
    rows: "4",
  });
  if (field.kind === "list") area.placeholder = t("settings.list.hint");
  area.addEventListener("change", () => {
    const parsed = parseInput(field, area.value);
    if (parsed.ok) onCommit(parsed.value);
    else onError(parsed.error);
  });
  return {
    element: area,
    focusTarget: area,
    setValue(v) {
      area.value = formatInput(field, v);
      area.rows = Math.min(12, Math.max(3, area.value.split("\n").length + 1));
    },
    setDisabled(d) {
      area.disabled = d;
    },
  };
}

function kvControl(doc, field, id, onCommit, onError) {
  const wrap = el(doc, "div", { class: "set-kv", id, role: "group" });
  const rows = el(doc, "div", { class: "set-kv-rows" });
  const add = el(doc, "button", { type: "button", class: "set-small", text: t("settings.kv.add") });
  const json = areaControl(doc, { ...field, kind: "object" }, `${id}-json`, onCommit, onError);
  wrap.append(rows, add, json.element);
  let disabled = false;
  let mode = "kv";
  let shown = false;

  const collect = () => {
    const out = {};
    for (const row of rows.querySelectorAll(".set-kv-row")) {
      const [k, v] = row.querySelectorAll("input");
      const key = k.value.trim();
      if (key === "" && v.value.trim() === "") continue;
      if (key === "") return { error: t("settings.kv.emptyKey") };
      if (Object.prototype.hasOwnProperty.call(out, key)) return { error: t("settings.kv.duplicate", { key }) };
      // defineProperty: a "__proto__" key stays an ordinary entry.
      Object.defineProperty(out, key, { value: parseCell(v.value), enumerable: true, writable: true, configurable: true });
    }
    return { value: out };
  };
  const commit = () => {
    const r = collect();
    if (r.error) onError(r.error);
    else onCommit(r.value);
  };
  const addRow = (key, value) => {
    const k = el(doc, "input", {
      type: "text",
      class: "set-input",
      "aria-label": t("settings.kv.key"),
      spellcheck: "false",
    });
    const v = el(doc, "input", {
      type: "text",
      class: "set-input",
      "aria-label": t("settings.kv.value"),
      spellcheck: "false",
    });
    const remove = el(doc, "button", {
      type: "button",
      class: "set-icon",
      "aria-label": t("settings.kv.remove"),
      title: t("settings.kv.remove"),
      text: "✕",
    });
    k.value = key;
    v.value = value;
    k.disabled = v.disabled = remove.disabled = disabled;
    k.addEventListener("change", commit);
    v.addEventListener("change", commit);
    remove.addEventListener("click", () => {
      row.remove();
      commit();
    });
    const row = el(doc, "div", { class: "set-kv-row" }, [k, v, remove]);
    rows.append(row);
    return k;
  };
  add.addEventListener("click", () => addRow("", "").focus());
  return {
    element: wrap,
    get focusTarget() {
      return mode === "kv" ? rows.querySelector("input") || add : json.focusTarget;
    },
    setValue(v) {
      const value = v === null || v === undefined ? {} : v;
      const next = isFlatObject(value) ? "kv" : "json";
      if (shown && mode === "kv" && next === "kv") {
        // Same entries as on screen (the reply to the user's own edit): keep
        // the inputs, so focus, the caret and a new empty row survive.
        const current = collect();
        if (!current.error && deepEqual(current.value, value)) return;
      }
      shown = true;
      mode = next;
      rows.replaceChildren();
      rows.hidden = add.hidden = mode !== "kv";
      json.element.hidden = mode !== "json";
      if (mode === "kv") for (const [key, val] of Object.entries(value)) addRow(key, formatCell(val));
      else json.setValue(value);
    },
    setDisabled(d) {
      disabled = d;
      for (const node of wrap.querySelectorAll("input, button")) node.disabled = d;
      json.setDisabled(d);
    },
  };
}

function strokesControl(doc, field, id, onCommit, onError, keys) {
  const wrap = el(doc, "div", { class: "set-strokes", role: "group" });
  const input = el(doc, "input", {
    id,
    type: "text",
    class: "set-input wmux-mono",
    spellcheck: "false",
    autocomplete: "off",
  });
  const record = el(doc, "button", { type: "button", class: "set-small", text: t("settings.shortcuts.record") });
  wrap.append(input, record);
  let stop = null;
  input.addEventListener("change", () => {
    const parsed = parseInput(field, input.value);
    if (parsed.ok) onCommit(parsed.value);
    else onError(parsed.error);
  });
  const end = () => {
    if (!stop) return;
    stop();
    stop = null;
    record.textContent = t("settings.shortcuts.record");
    record.removeAttribute("aria-pressed");
  };
  record.addEventListener("click", () => {
    if (stop) {
      end();
      return;
    }
    record.textContent = t("settings.shortcuts.listening");
    record.setAttribute("aria-pressed", "true");
    stop = startRecorder(doc, keys, {
      owner: record,
      onStroke(stroke) {
        end();
        onCommit(stroke);
      },
      onCancel: end,
    });
  });
  return {
    element: wrap,
    focusTarget: input,
    setValue(v) {
      input.value = formatInput(field, v);
    },
    setDisabled(d) {
      input.disabled = d;
      record.disabled = d;
      if (d) end();
    },
  };
}

/** Cancel functions of the recorders that are listening (see cancelRecorders). */
const activeRecorders = new Set();

/**
 * Capture the next stroke on `doc` (capture phase, so nothing else sees it).
 * Escape without modifiers cancels; modifier-only presses are ignored.
 * Calls keys.startCapture() so native's KeyRouter skips this panel.
 * `owner` (an element, or a function returning the current one) is the
 * control showing "Listening…": a click or a focus move outside it cancels,
 * and once it has left the document the next key cancels without being
 * consumed, so a stale recorder never swallows typing or saves it.
 * Window blur cancels too. Returns a stop function.
 */
export function startRecorder(doc, keys, { onStroke, onCancel, owner }) {
  const release = keys && typeof keys.startCapture === "function" ? keys.startCapture() : () => {};
  const view = doc.defaultView;
  const hasOwner = owner !== undefined && owner !== null;
  const ownerEl = () => (typeof owner === "function" ? owner() : owner) || null;
  let stopped = false;
  const onKey = (e) => {
    if (e.type !== "keydown") return;
    if (hasOwner) {
      const o = ownerEl();
      if (!o || !o.isConnected) {
        cancel(); // re-rendered away: the key belongs to whatever has focus now
        return;
      }
    }
    e.preventDefault();
    e.stopPropagation();
    if (e.key === "Escape" && !e.ctrlKey && !e.altKey && !e.shiftKey && !e.metaKey) {
      cancel();
      return;
    }
    const stroke = strokeFromKeyboardEvent(e);
    if (stroke) onStroke(stroke);
  };
  const onOutside = (e) => {
    const o = ownerEl();
    if (!o || typeof o.contains !== "function" || !(e.target && o.contains(e.target))) cancel();
  };
  const onBlur = () => cancel();
  function stop() {
    if (stopped) return;
    stopped = true;
    activeRecorders.delete(cancel);
    doc.removeEventListener("keydown", onKey, true);
    if (hasOwner) {
      doc.removeEventListener("mousedown", onOutside, true);
      doc.removeEventListener("focusin", onOutside, true);
    }
    if (view) view.removeEventListener("blur", onBlur);
    release();
  }
  function cancel() {
    if (stopped) return;
    onCancel();
    stop(); // in case onCancel did not call the stop function
  }
  activeRecorders.add(cancel);
  doc.addEventListener("keydown", onKey, true);
  if (hasOwner) {
    doc.addEventListener("mousedown", onOutside, true);
    doc.addEventListener("focusin", onOutside, true);
  }
  if (view) view.addEventListener("blur", onBlur);
  return stop;
}

/** Cancel every listening recorder (the page is about to re-render its rows). */
export function cancelRecorders() {
  for (const cancel of Array.from(activeRecorders)) cancel();
}

/**
 * Build the control for a field. `onCommit(value)` receives parsed values,
 * `onError(message)` unparsable input; `keys` is the keys.js controller
 * (shortcut recorder).
 */
export function createControl(doc, field, { onCommit, onError, keys }) {
  const id = uniqueId("set-ctl");
  switch (field.kind) {
    case "bool":
      return boolControl(doc, field, id, onCommit);
    case "enum":
      return enumControl(doc, field, id, onCommit);
    case "color":
      return colorControl(doc, field, id, onCommit, onError);
    case "list":
    case "json":
      return areaControl(doc, field, id, onCommit, onError);
    case "object":
      return kvControl(doc, field, id, onCommit, onError);
    case "strokes":
      return strokesControl(doc, field, id, onCommit, onError, keys);
    default:
      return textControl(doc, field, id, onCommit, onError);
  }
}
