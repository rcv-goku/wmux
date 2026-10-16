/**
 * Keyboard Shortcuts section (DOM; ADR-5.8, ADR-8.6). Lists every action from
 * `wmux.shortcuts.list` with its effective bindings; click a binding to record
 * (keys.startCapture() so native's KeyRouter skips the panel), X unbinds and
 * turns into Restore, per-action reset, search, find-by-keys, conflict and
 * reserved-key validation (local, then `wmux.shortcuts.validate`), keymap
 * presets with a change report, Reset Default Shortcuts, the Pane Resize Step
 * row and the Shortcut Chords help. Saving goes through `wmux.shortcuts.set`
 * (native writes `shortcuts.bindings.<id>` in wmux.json).
 */
import { el, startRecorder } from "./controls.js";
import {
  CATEGORIES,
  actionsUsingStroke,
  displayBinding,
  displayStroke,
  filterActions,
  isCustomized,
  keyList,
  normalizeShortcutList,
  validateBinding,
} from "./shortcuts.js";
import { t } from "./strings.js";

const UNSUPPORTED = new Set(["method_not_found", "not_supported"]);
const PANE_RESIZE_PATH = "app.paneResizeStepPixels";

function message(err) {
  return err && typeof err.message === "string" && err.message ? err.message : String(err);
}

function code(err) {
  return err && typeof err.code === "string" ? err.code : "";
}

function asStrings(list) {
  return Array.isArray(list) ? list.filter((x) => typeof x === "string" && x) : [];
}

function bindingText(value) {
  const list = keyList(value);
  return list.length ? list.map(displayBinding).join(", ") : t("settings.shortcuts.none");
}

/**
 * Report lines for an apply_preset reply: {changes: [{id, title?, old, new}],
 * kept: [id | {id, title}], warnings: [..], notes: [..]}.
 */
export function presetReport(result, titleOf) {
  const lines = [];
  const name = (item) => (item && typeof item === "object" ? item.title || titleOf(item.id) : titleOf(item));
  const r = result && typeof result === "object" ? result : {};
  for (const c of Array.isArray(r.changes) ? r.changes : []) {
    if (!c || typeof c.id !== "string") continue;
    lines.push({
      kind: "change",
      text: t("settings.shortcuts.presetChange", { action: name(c), old: bindingText(c.old), new: bindingText(c.new) }),
    });
  }
  for (const k of Array.isArray(r.kept) ? r.kept : []) {
    if (typeof k !== "string" && !(k && typeof k.id === "string")) continue;
    lines.push({ kind: "kept", text: t("settings.shortcuts.presetKept", { action: name(k) }) });
  }
  for (const w of asStrings(r.warnings)) lines.push({ kind: "warning", text: w });
  for (const n of asStrings(r.notes)) lines.push({ kind: "note", text: n });
  if (lines.length === 0) lines.push({ kind: "note", text: t("settings.shortcuts.presetNoChanges") });
  return lines;
}

export function createShortcutsView(ctx) {
  const { document: doc, call, keys, confirm, setStatus, renderRow, state, openDocs } = ctx;
  const model = {
    loaded: false,
    loading: null,
    error: "",
    actions: [],
    presets: [],
    preset: null,
    query: "",
    detect: null, // null | "" (listening) | canonical stroke
    previous: new Map(), // id -> keys before the last unbind
    messages: new Map(), // id -> {errors, warnings}
    report: [],
  };
  let root = null;
  let listEl = null;
  let recording = null; // {id, stop} while a recorder runs ("detect" for find-by-keys)

  const titleOf = (id) => {
    const a = model.actions.find((x) => x.id === id);
    return a ? a.title : String(id);
  };

  async function load() {
    if (model.loading) return model.loading;
    model.loading = (async () => {
      try {
        const data = normalizeShortcutList(await call("wmux.shortcuts.list", {}));
        model.actions = data.actions;
        model.presets = data.presets;
        model.preset = data.preset;
        model.loaded = true;
        model.error = "";
      } catch (err) {
        model.error = message(err);
      } finally {
        model.loading = null;
      }
      paint();
    })();
    return model.loading;
  }

  /** The keys button of an action's row in the current list, or null. */
  function keysButtonFor(id) {
    if (!listEl) return null;
    for (const row of listEl.querySelectorAll(".set-sc-row")) {
      if (row.dataset.action === id) return row.querySelector(".set-sc-keys");
    }
    return null;
  }

  /** Show an action's bindings (or "Listening…") on its keys button. */
  function fillKeys(button, action, listening) {
    button.replaceChildren();
    button.setAttribute("aria-pressed", listening ? "true" : "false");
    button.setAttribute(
      "aria-label",
      t("settings.shortcuts.recordLabel", { action: action.title, keys: bindingText(action.keys) }),
    );
    if (listening) button.textContent = t("settings.shortcuts.listening");
    else if (action.keys.length === 0)
      button.append(el(doc, "span", { class: "wmux-muted", text: t("settings.shortcuts.none") }));
    else for (const k of action.keys) button.append(el(doc, "kbd", { class: "set-kbd", text: displayBinding(k) }));
  }

  /* Painting replaces elements: keep keyboard focus on the same control. */
  const ROW_BUTTONS = ["set-sc-keys", "set-sc-unbind", "set-sc-restore", "set-sc-reset"];
  /** Unbind (X) turns into Restore and back; otherwise focus falls back to the keys button. */
  const ROW_FALLBACK = { "set-sc-unbind": ["set-sc-restore"], "set-sc-restore": ["set-sc-unbind"] };
  const ID_FALLBACK = { "set-sc-detect-stop": ["set-sc-detect"] };

  function focusMarker() {
    const a = doc.activeElement;
    if (!root || !a || !root.contains(a) || typeof a.closest !== "function") return null;
    const actionRowEl = a.closest(".set-sc-row");
    if (actionRowEl) {
      const cls = ROW_BUTTONS.find((c) => a.classList.contains(c)) || "set-sc-keys";
      return { action: actionRowEl.dataset.action, cls };
    }
    const settingRow = a.closest(".set-row[data-path]");
    if (settingRow) return { path: settingRow.dataset.path };
    return a.id ? { id: a.id } : null;
  }

  function restoreFocus(marker) {
    if (!marker || !root || !root.isConnected) return;
    const candidates = [];
    if (marker.action !== undefined) {
      const row = Array.from(root.querySelectorAll(".set-sc-row")).find((r) => r.dataset.action === marker.action);
      if (row) {
        for (const cls of [marker.cls, ...(ROW_FALLBACK[marker.cls] || []), "set-sc-keys"])
          candidates.push(row.querySelector(`.${cls}`));
      }
    } else if (marker.path !== undefined) {
      const row = Array.from(root.querySelectorAll(".set-row[data-path]")).find((r) => r.dataset.path === marker.path);
      if (row) candidates.push(row.querySelector(".set-row-control input, .set-row-control select"));
    } else {
      for (const id of [marker.id, ...(ID_FALLBACK[marker.id] || [])]) candidates.push(doc.getElementById(id));
    }
    const target = candidates.find((node) => node && root.contains(node) && !node.disabled);
    if (target && doc.activeElement !== target) target.focus();
  }

  function stopRecording() {
    if (!recording) return;
    const r = recording;
    recording = null;
    r.stop();
    if (r.id === "detect") {
      if (model.detect === "") model.detect = null;
      return;
    }
    // Put the bindings back in place (no repaint, so a click that ended the
    // recording still reaches its target).
    const action = model.actions.find((a) => a.id === r.id);
    const button = keysButtonFor(r.id);
    if (action && button) fillKeys(button, action, false);
  }

  function replaceAction(updated) {
    const i = model.actions.findIndex((a) => a.id === updated.id);
    if (i >= 0) model.actions[i] = updated;
  }

  /** Save `keysToSave` (canonical bindings; [] unbinds) for an action. */
  async function save(action, keysToSave, warnings) {
    try {
      const result = await call("wmux.shortcuts.set", { id: action.id, keys: keysToSave });
      const fresh = result && result.action ? normalizeShortcutList({ actions: [result.action] }).actions[0] : null;
      replaceAction(fresh || { ...action, keys: keysToSave.slice(), source: "wmux.json", managed: null });
      model.messages.set(action.id, { errors: [], warnings: warnings || [] });
      if (keysToSave.length)
        setStatus(
          t("settings.shortcuts.saved", { keys: keysToSave.map(displayBinding).join(", "), action: action.title }),
        );
      paintList();
      return true;
    } catch (err) {
      model.messages.set(action.id, {
        errors: [t("settings.shortcuts.saveFailed", { message: message(err) })],
        warnings: [],
      });
      paintList();
      return false;
    }
  }

  /** Validate a recorded stroke locally and natively; save when clean. */
  async function record(action, strokes) {
    const local = validateBinding(model.actions, action, strokes);
    let errors = local.errors.slice();
    let warnings = local.warnings.slice();
    if (errors.length === 0 && local.binding) {
      try {
        const r = await call("wmux.shortcuts.validate", { id: action.id, keys: [local.binding] });
        if (r && typeof r === "object") {
          errors = errors.concat(asStrings(r.errors));
          for (const c of Array.isArray(r.conflicts) ? r.conflicts : []) {
            if (!c || typeof c.id !== "string") continue;
            const text = t("settings.shortcuts.conflict", {
              action: c.title || titleOf(c.id),
              keys: bindingText(c.keys),
            });
            if (!errors.includes(text)) errors.push(text);
          }
          for (const w of asStrings(r.warnings)) if (!warnings.includes(w)) warnings.push(w);
          if (r.ok === false && errors.length === 0) errors.push(t("settings.shortcuts.invalid"));
        }
      } catch (err) {
        if (!UNSUPPORTED.has(code(err))) errors.push(t("settings.shortcuts.saveFailed", { message: message(err) }));
      }
    }
    if (errors.length > 0) {
      model.messages.set(action.id, { errors, warnings });
      paintList();
      return false;
    }
    return save(action, [local.binding], warnings);
  }

  function startRecording(action, button) {
    stopRecording();
    fillKeys(button, action, true);
    const stop = startRecorder(doc, keys, {
      // The row may be repainted while listening: follow its current button.
      owner: () => keysButtonFor(action.id),
      onStroke(stroke) {
        stopRecording();
        record(action, [stroke]);
      },
      onCancel: stopRecording,
    });
    recording = { id: action.id, stop };
  }

  async function unbind(action) {
    if (action.keys.length) model.previous.set(action.id, action.keys.slice());
    return save(action, [], []);
  }

  async function restore(action) {
    const prev = model.previous.get(action.id);
    if (!prev) return false;
    const ok = await save(action, prev, []);
    if (ok) model.previous.delete(action.id);
    paintList();
    return ok;
  }

  async function resetAction(action) {
    try {
      await call("wmux.settings.unset", { path: `shortcuts.bindings.${action.id}` });
      replaceAction({ ...action, keys: action.defaultKeys.slice(), source: "default", managed: null });
      model.previous.delete(action.id);
      model.messages.delete(action.id);
    } catch (err) {
      model.messages.set(action.id, {
        errors: [t("settings.shortcuts.saveFailed", { message: message(err) })],
        warnings: [],
      });
    }
    paintList();
    await load();
  }

  async function resetDefaults() {
    const ok = await confirm(t("settings.shortcuts.resetConfirm"), t("settings.shortcuts.resetOk"));
    if (!ok) return false;
    try {
      try {
        await call("wmux.settings.reset_shortcuts", {});
      } catch (err) {
        if (!UNSUPPORTED.has(code(err))) throw err;
        for (const a of model.actions) {
          if (a.source === "wmux.json" && !a.locked)
            await call("wmux.settings.unset", { path: `shortcuts.bindings.${a.id}` });
        }
      }
      model.previous.clear();
      model.messages.clear();
      setStatus(t("settings.shortcuts.resetDone"));
    } catch (err) {
      setStatus(t("settings.shortcuts.saveFailed", { message: message(err) }), "error");
    }
    await load();
    return true;
  }

  async function applyPreset(name) {
    const preset = model.presets.find((p) => p.name === name);
    if (!preset) return false;
    const body = [t("settings.shortcuts.presetConfirm", { preset: preset.title }), preset.description, preset.warning]
      .filter(Boolean)
      .join("\n\n");
    if (!(await confirm(body, t("settings.shortcuts.presetApply")))) return false;
    try {
      const result = await call("wmux.settings.apply_preset", { name });
      model.report = presetReport(result, titleOf);
      model.preset = name;
    } catch (err) {
      model.report = [{ kind: "error", text: t("settings.shortcuts.presetFailed", { message: message(err) }) }];
    }
    await load();
    return true;
  }

  function startDetect() {
    stopRecording();
    model.detect = "";
    paint();
    const stop = startRecorder(doc, keys, {
      onStroke(stroke) {
        stopRecording();
        model.detect = stroke;
        paint();
      },
      onCancel() {
        stopRecording();
        model.detect = null;
        paint();
      },
    });
    recording = { id: "detect", stop };
  }

  /* ------------------------------------------------------------ painting */

  function messagesFor(action) {
    const m = model.messages.get(action.id);
    const out = [];
    if (!m) return out;
    for (const e of m.errors) out.push(el(doc, "p", { class: "set-row-error", role: "alert", text: e }));
    for (const w of m.warnings) out.push(el(doc, "p", { class: "set-row-warning", text: w }));
    return out;
  }

  function actionRow(action) {
    const readOnly = action.managed !== null;
    const row = el(doc, "li", { class: "set-sc-row", "data-action": action.id });
    const text = el(doc, "div", { class: "set-row-text" });
    text.append(el(doc, "span", { class: "set-row-title", text: action.title }));
    if (action.whenLabel) text.append(el(doc, "p", { class: "set-row-desc set-sc-when", text: action.whenLabel }));
    if (readOnly) {
      const note =
        action.managed === "policy" ? t("settings.shortcuts.managed.policy") : t("settings.shortcuts.managed.cmux");
      text.append(el(doc, "p", { class: "set-row-managed", text: note }));
    }
    if (!action.available)
      text.append(el(doc, "p", { class: "set-row-desc", text: t("settings.shortcuts.unavailableAction") }));
    text.append(...messagesFor(action));

    const ctl = el(doc, "div", { class: "set-row-control set-sc-control" });
    const isRec = Boolean(recording && recording.id === action.id);
    const keysBtn = el(doc, "button", { type: "button", class: "set-sc-keys", disabled: readOnly });
    fillKeys(keysBtn, action, isRec);
    keysBtn.title = t("settings.shortcuts.record");
    keysBtn.addEventListener("click", () => {
      if (recording && recording.id === action.id) stopRecording();
      else startRecording(action, keysBtn);
    });
    ctl.append(keysBtn);
    if (!readOnly) {
      if (action.keys.length === 0 && model.previous.has(action.id)) {
        const r = el(doc, "button", {
          type: "button",
          class: "set-icon set-sc-restore",
          title: t("settings.shortcuts.restore"),
          "aria-label": t("settings.shortcuts.restoreLabel", { action: action.title }),
          text: "↶",
        });
        r.addEventListener("click", () => restore(action));
        ctl.append(r);
      } else if (action.keys.length > 0) {
        const x = el(doc, "button", {
          type: "button",
          class: "set-icon set-sc-unbind",
          title: t("settings.shortcuts.unbind"),
          "aria-label": t("settings.shortcuts.unbindLabel", { action: action.title }),
          text: "✕",
        });
        x.addEventListener("click", () => unbind(action));
        ctl.append(x);
      }
      if (action.source === "wmux.json" && isCustomized(action)) {
        const d = el(doc, "button", {
          type: "button",
          class: "set-small set-sc-reset",
          title: t("settings.shortcuts.resetOne"),
          "aria-label": t("settings.reset.label", { title: action.title }),
          text: t("settings.reset"),
        });
        d.addEventListener("click", () => resetAction(action));
        ctl.append(d);
      }
    }
    row.append(text, ctl);
    return row;
  }

  function visibleActions() {
    if (typeof model.detect === "string" && model.detect) return actionsUsingStroke(model.actions, model.detect);
    return filterActions(model.actions, model.query);
  }

  function paintList() {
    if (!listEl) return;
    const marker = focusMarker();
    fillList();
    restoreFocus(marker);
  }

  function fillList() {
    listEl.replaceChildren();
    const actions = visibleActions();
    if (actions.length === 0) {
      const text = model.detect
        ? t("settings.shortcuts.detectNone", { keys: displayStroke(model.detect) })
        : t("settings.shortcuts.noMatch");
      listEl.append(el(doc, "p", { class: "wmux-muted set-empty", text }));
      return;
    }
    for (const cat of CATEGORIES) {
      const inCat = actions.filter((a) => a.category === cat);
      if (inCat.length === 0) continue;
      const group = el(doc, "div", { class: "set-sc-group", "data-category": cat });
      group.append(el(doc, "h3", { class: "set-subheading", text: t(`settings.shortcuts.category.${cat}`) }));
      const ul = el(doc, "ul", { class: "set-sc-list" });
      for (const a of inCat) ul.append(actionRow(a));
      group.append(ul);
      listEl.append(group);
    }
  }

  function presetBar() {
    const bar = el(doc, "div", { class: "set-sc-presets" });
    const id = "set-sc-preset";
    const label = el(doc, "label", { class: "set-row-title", text: t("settings.shortcuts.preset") });
    label.htmlFor = id;
    const select = el(doc, "select", { id, class: "set-select" });
    for (const p of model.presets) select.append(el(doc, "option", { value: p.name, text: p.title }));
    if (model.preset && model.presets.some((p) => p.name === model.preset)) select.value = model.preset;
    const apply = el(doc, "button", {
      type: "button",
      id: "set-sc-preset-apply",
      text: t("settings.shortcuts.presetApply"),
    });
    apply.addEventListener("click", () => applyPreset(select.value));
    bar.append(label, select, apply);
    if (model.report.length) {
      const ul = el(doc, "ul", { class: "set-sc-report", role: "status" });
      for (const line of model.report)
        ul.append(el(doc, "li", { class: `set-sc-report-${line.kind}`, text: line.text }));
      bar.append(ul);
    }
    return bar;
  }

  function toolbar() {
    const bar = el(doc, "div", { class: "set-sc-toolbar" });
    const search = el(doc, "input", {
      type: "search",
      id: "set-sc-search",
      class: "set-input",
      placeholder: t("settings.shortcuts.search"),
      "aria-label": t("settings.shortcuts.search"),
      autocomplete: "off",
      spellcheck: "false",
    });
    search.value = model.query;
    search.addEventListener("input", () => {
      model.query = search.value.slice(0, 256);
      paintList();
    });
    const detect = el(doc, "button", { type: "button", id: "set-sc-detect", text: t("settings.shortcuts.detect") });
    detect.addEventListener("click", () => startDetect());
    const reset = el(doc, "button", {
      type: "button",
      id: "set-sc-reset-defaults",
      text: t("settings.shortcuts.resetDefaults"),
    });
    reset.addEventListener("click", () => resetDefaults());
    bar.append(search, detect, reset);
    return bar;
  }

  function detectBanner() {
    if (model.detect === null) return null;
    const banner = el(doc, "div", { class: "set-sc-detect", role: "status" });
    const text =
      model.detect === ""
        ? t("settings.shortcuts.detectPrompt")
        : t("settings.shortcuts.detectFound", { keys: displayStroke(model.detect) });
    const stop = el(doc, "button", {
      type: "button",
      id: "set-sc-detect-stop",
      class: "set-small",
      text: t("settings.shortcuts.detectStop"),
    });
    stop.addEventListener("click", () => {
      stopRecording();
      model.detect = null;
      paint();
    });
    banner.append(el(doc, "span", { text }), stop);
    return banner;
  }

  function chordsHelp() {
    const card = el(doc, "section", { class: "wmux-card set-card set-sc-chords" });
    card.append(el(doc, "h3", { class: "set-subheading", text: t("settings.shortcuts.chords") }));
    card.append(el(doc, "p", { text: t("settings.shortcuts.chordsBody") }));
    const docs = el(doc, "button", {
      type: "button",
      id: "set-sc-chord-docs",
      class: "wmux-link",
      text: t("settings.shortcuts.chordDocs"),
    });
    docs.addEventListener("click", () => openDocs("shortcut-chords"));
    const open = el(doc, "button", { type: "button", id: "set-sc-open-json", text: t("settings.shortcuts.openJson") });
    open.addEventListener("click", () => {
      call("wmux.settings.open_file", { file: "wmux" }).catch((err) =>
        setStatus(t("settings.json.failed", { message: message(err) }), "error"),
      );
    });
    card.append(el(doc, "div", { class: "set-actions" }, [docs, open]));
    return card;
  }

  function paint() {
    if (!root) return;
    const marker = focusMarker();
    build();
    restoreFocus(marker);
  }

  function build() {
    root.replaceChildren();
    listEl = null;
    const field = state.byPath.get(PANE_RESIZE_PATH);
    if (field) root.append(el(doc, "div", { class: "set-rows set-sc-pane-resize" }, [renderRow(field, []).element]));
    if (model.error) {
      root.append(
        el(doc, "p", {
          class: "set-row-error",
          role: "alert",
          text: t("settings.shortcuts.unavailable", { message: model.error }),
        }),
      );
      root.append(chordsHelp());
      return;
    }
    if (!model.loaded) {
      root.append(el(doc, "p", { class: "wmux-muted", text: t("settings.loading") }));
      return;
    }
    root.append(presetBar(), toolbar());
    const banner = detectBanner();
    if (banner) root.append(banner);
    listEl = el(doc, "div", { class: "set-sc-groups", id: "set-sc-groups" });
    root.append(listEl);
    fillList();
    root.append(chordsHelp());
  }

  return {
    model,
    render() {
      stopRecording();
      root = el(doc, "div", { class: "set-shortcuts" });
      paint();
      if (!model.loaded && !model.loading) load();
      return root;
    },
    reload: load,
    record,
    unbind,
    restore,
    resetAction,
    resetDefaults,
    applyPreset,
    startDetect,
    stopRecording,
    isRecording: () => recording !== null,
    onSettingsChanged() {},
  };
}
