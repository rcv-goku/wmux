/**
 * Settings panel application: PanelKind "settings" (ARCHITECTURE ADR-5.8,
 * ADR-6.11), entry https://settings.wmux.example/settings/index.html. The
 * native contract (params, methods, events) is documented in README.md.
 *
 *   const app = createApp({ document });
 *   await app.start();
 *
 * The document, bridge and keys controller are injectable so the jsdom tests
 * in test/web-node/settings/ drive the real code.
 */
import { wmux as defaultBridge } from "../_shared/wmux-bridge.js";
import { installKeys } from "../_shared/keys.js";
import { applyStrings } from "../_shared/strings.js";
import { cancelRecorders, createControl, el, uniqueId } from "./controls.js";
import { normalizeEffective, rowState } from "./effective.js";
import {
  deepEqual,
  fieldHaystack,
  flattenSchema,
  highlightRanges,
  matchesTokens,
  queryTokens,
  validateValue,
} from "./schema.js";
import { SECTIONS, findSection, resolveTarget, sectionTitle } from "./sections.js";
import { createShortcutsView } from "./shortcuts-view.js";
import { t } from "./strings.js";
import { createThemesView } from "./themes-view.js";

/** Error codes that mean "native does not implement this method". */
export const UNSUPPORTED_CODES = new Set(["method_not_found", "not_supported", "forbidden"]);
const STATUS_MS = 4000;

/**
 * Settings owned by a hand-built page, never shown as generic rows (in their
 * section or in search results). `shortcuts.bindings` belongs to the shortcut
 * editor: its effective value merges cmux.json (macOS strokes) into
 * wmux.json, so saving it as one object would copy strokes wmux.json rejects.
 */
export const EDITOR_PATHS = new Set(["shortcuts.bindings"]);

export function errorMessage(err) {
  return err && typeof err.message === "string" && err.message ? err.message : String(err);
}

export function errorCode(err) {
  return err && typeof err.code === "string" ? err.code : "";
}

/** Append `text` to `parent`, wrapping query matches in <mark>. */
export function appendHighlighted(doc, parent, text, tokens) {
  const source = String(text ?? "");
  let at = 0;
  for (const [start, end] of highlightRanges(source, tokens || [])) {
    if (start > at) parent.append(doc.createTextNode(source.slice(at, start)));
    parent.append(el(doc, "mark", { class: "set-mark", text: source.slice(start, end) }));
    at = end;
  }
  if (at < source.length) parent.append(doc.createTextNode(source.slice(at)));
  return parent;
}

/**
 * @param {{document?: Document, bridge?: object, keys?: object, docsUrl?: string}} [options]
 */
export function createApp(options) {
  const opts = options || {};
  const doc = opts.document || globalThis.document;
  const bridge = opts.bridge || defaultBridge;
  const keys = opts.keys || installKeys();
  const $ = (id) => doc.getElementById(id);
  const els = {
    navList: $("set-nav-list"),
    search: $("set-search"),
    main: $("set-main"),
    content: $("set-content"),
    status: $("set-status"),
    confirm: $("set-confirm"),
    confirmBody: $("set-confirm-body"),
    confirmOk: $("set-confirm-ok"),
    confirmCancel: $("set-confirm-cancel"),
  };

  const state = {
    loaded: false,
    fields: [],
    byPath: new Map(),
    effective: new Map(),
    overridden: new Set(),
    section: "app",
    query: "",
    files: {},
    docsUrl: typeof opts.docsUrl === "string" ? opts.docsUrl : "",
  };
  /** path -> Set of live row objects (a field may show in two places). */
  const rows = new Map();
  const cleanup = [];
  let statusTimer = null;
  let confirmResolve = null;
  let confirmOpener = null;

  /* ------------------------------------------------------------- helpers */

  function call(method, params) {
    return bridge.call(method, params || {});
  }

  function setStatus(message, kind) {
    if (statusTimer) clearTimeout(statusTimer);
    els.status.textContent = message || "";
    els.status.dataset.kind = kind || "info";
    statusTimer = message
      ? setTimeout(() => {
          els.status.textContent = "";
          statusTimer = null;
        }, STATUS_MS)
      : null;
  }

  /** In-page confirmation dialog; resolves true for OK. */
  function confirm(body, okLabel) {
    if (confirmResolve) confirmResolve(false);
    confirmOpener = doc.activeElement;
    els.confirmBody.textContent = body;
    els.confirmOk.textContent = okLabel || "OK";
    els.confirm.hidden = false;
    els.confirmCancel.focus();
    return new Promise((resolve) => {
      confirmResolve = resolve;
    });
  }

  function closeConfirm(result) {
    if (!confirmResolve) return;
    const resolve = confirmResolve;
    confirmResolve = null;
    els.confirm.hidden = true;
    if (confirmOpener && typeof confirmOpener.focus === "function" && confirmOpener.isConnected) confirmOpener.focus();
    confirmOpener = null;
    resolve(result);
  }

  function wireConfirm() {
    els.confirmOk.addEventListener("click", () => closeConfirm(true));
    els.confirmCancel.addEventListener("click", () => closeConfirm(false));
    els.confirm.addEventListener("keydown", (e) => {
      if (e.key === "Escape") {
        e.preventDefault();
        e.stopPropagation();
        closeConfirm(false);
      } else if (e.key === "Tab") {
        // Two buttons: keep focus inside the dialog.
        e.preventDefault();
        (doc.activeElement === els.confirmOk ? els.confirmCancel : els.confirmOk).focus();
      }
    });
  }

  /* ---------------------------------------------------------------- rows */

  function stateOf(field) {
    return rowState(field, state.effective.get(field.path), {
      overridden: state.overridden.has(field.path),
      deepEqual,
    });
  }

  function badge(text, cls, title) {
    return el(doc, "span", { class: `set-badge ${cls}`, text, title });
  }

  /** Build a settings row for `field`; `tokens` highlight search matches. */
  function renderRow(field, tokens) {
    const titleId = uniqueId("set-title");
    const row = { field, busy: false, element: null, control: null, error: "" };
    const control = createControl(doc, field, {
      keys,
      onCommit: (value) => commit(row, value),
      onError: (message) => showRowError(row, message),
    });
    row.control = control;
    const label = el(doc, "label", { class: "set-row-title", id: titleId });
    if (control.focusTarget && control.focusTarget.id) label.htmlFor = control.focusTarget.id;
    appendHighlighted(doc, label, field.title, tokens);
    if (!control.focusTarget || control.focusTarget !== control.element)
      control.element.setAttribute("aria-labelledby", titleId);
    row.badges = el(doc, "span", { class: "set-badges" });
    const head = el(doc, "div", { class: "set-row-head" }, [label, row.badges]);
    const desc = field.description
      ? appendHighlighted(doc, el(doc, "p", { class: "set-row-desc" }), field.description, tokens)
      : null;
    const key = appendHighlighted(doc, el(doc, "code", { class: "set-row-key" }), field.path, tokens);
    row.managed = el(doc, "p", { class: "set-row-managed", hidden: true });
    row.managedText = el(doc, "span");
    row.override = el(doc, "button", {
      type: "button",
      class: "wmux-link set-override",
      text: t("settings.managed.override"),
    });
    row.override.addEventListener("click", () => {
      state.overridden.add(field.path);
      updatePath(field.path);
      const target = row.control.focusTarget;
      if (target && typeof target.focus === "function") target.focus();
    });
    row.managed.append(row.managedText, row.override);
    row.project = el(doc, "p", { class: "set-row-note wmux-muted", text: t("settings.project.note"), hidden: true });
    row.errorEl = el(doc, "p", { class: "set-row-error", role: "alert", hidden: true });
    row.reset = el(doc, "button", {
      type: "button",
      class: "set-small set-reset",
      text: t("settings.reset"),
      "aria-label": t("settings.reset.label", { title: field.title }),
      hidden: true,
    });
    row.reset.addEventListener("click", () => resetField(row));
    const text = el(doc, "div", { class: "set-row-text" }, [head, desc, key, row.managed, row.project, row.errorEl]);
    const ctl = el(doc, "div", { class: "set-row-control" }, [control.element, row.reset]);
    row.element = el(doc, "div", { class: "set-row", "data-path": field.path, "data-kind": field.kind }, [text, ctl]);
    if (!rows.has(field.path)) rows.set(field.path, new Set());
    rows.get(field.path).add(row);
    updateRow(row);
    return row;
  }

  /** Refresh a row from the effective state; `keepValue` leaves the control's text alone. */
  function updateRow(row, keepValue) {
    const s = stateOf(row.field);
    if (!keepValue) row.control.setValue(s.value);
    row.control.setDisabled(s.readOnly);
    row.element.classList.toggle("set-row-readonly", s.readOnly);
    row.element.dataset.source = s.source;
    row.badges.replaceChildren();
    if (s.source !== "default") {
      row.badges.append(
        badge(
          t(`settings.source.${s.source}`),
          `set-badge-source set-source-${s.source.replace(/\W/g, "")}`,
          t("settings.source.title", { source: t(`settings.source.${s.source}`) }),
        ),
      );
    }
    if (s.modified) row.badges.append(badge(t("settings.modified"), "set-badge-modified"));
    if (row.field.apply === "restart") row.badges.append(badge(t("settings.restart"), "set-badge-restart"));
    row.managed.hidden = !s.managed;
    const managedKey = {
      policy: "settings.managed.policy",
      project: "settings.managed.project",
      "cmux.json": "settings.managed.cmux",
    }[s.managed];
    row.managedText.textContent = managedKey ? t(managedKey) : "";
    row.override.hidden = s.managed !== "cmux.json";
    row.project.hidden = s.source !== "project";
    row.reset.hidden = !s.canReset;
    row.reset.disabled = row.busy;
    const error = row.error || s.error || "";
    row.errorEl.textContent = error;
    row.errorEl.hidden = error === "";
    row.element.classList.toggle("set-row-invalid", error !== "");
  }

  function updatePath(path) {
    const set = rows.get(path);
    if (!set) return;
    for (const row of set) {
      if (!row.element.isConnected) set.delete(row);
      else updateRow(row);
    }
  }

  function showRowError(row, message) {
    row.error = message || "";
    updateRow(row);
  }

  /** Apply a set/unset reply ({value, source, ...}) or refetch the effective values. */
  async function applyReply(path, result) {
    if (result && typeof result === "object" && Object.prototype.hasOwnProperty.call(result, "source")) {
      const entry = normalizeEffective({ values: { [path]: result } }).get(path);
      if (entry) {
        state.effective.set(path, entry);
        updatePath(path);
        return;
      }
    }
    await refreshEffective();
  }

  async function commit(row, value) {
    const { field } = row;
    const s = stateOf(field);
    if (s.readOnly) return;
    const invalid = validateValue(field, value);
    if (invalid) {
      showRowError(row, invalid);
      return;
    }
    row.error = "";
    if (deepEqual(value, s.value) && s.source === "wmux.json") {
      updateRow(row);
      return;
    }
    row.busy = true;
    // Keep the user's edit on screen while saving: showing the old value
    // would flicker and rebuild key-value rows under the caret.
    updateRow(row, true);
    try {
      const result = await call("wmux.settings.set", { path: field.path, value });
      row.busy = false;
      if (!result || !Object.prototype.hasOwnProperty.call(result, "source")) {
        state.effective.set(field.path, { value, source: "wmux.json", locked: false, error: null });
      }
      await applyReply(field.path, result && Object.prototype.hasOwnProperty.call(result, "source") ? result : null);
      setStatus(t("settings.saved"));
    } catch (err) {
      row.busy = false;
      row.error = errorMessage(err);
      updatePath(field.path);
      updateRow(row);
    }
  }

  async function resetField(row) {
    const { field } = row;
    row.busy = true;
    row.error = "";
    updateRow(row);
    try {
      const result = await call("wmux.settings.unset", { path: field.path });
      row.busy = false;
      state.overridden.delete(field.path);
      await applyReply(field.path, result);
    } catch (err) {
      row.busy = false;
      row.error = t("settings.saveFailed", { message: errorMessage(err) });
      updateRow(row);
    }
  }

  /* ---------------------------------------------------------------- data */

  async function loadSchema() {
    const result = await call("wmux.settings.schema", {});
    const schema = result && typeof result === "object" && result.properties ? result : result && result.schema;
    state.fields = flattenSchema(schema);
    state.byPath = new Map(state.fields.map((f) => [f.path, f]));
    if (result && typeof result.docs_url === "string") state.docsUrl = result.docs_url;
  }

  async function refreshEffective() {
    try {
      const result = await call("wmux.settings.get_effective", {});
      state.effective = normalizeEffective(result);
      if (result && result.files && typeof result.files === "object") state.files = result.files;
    } catch (err) {
      setStatus(t("settings.loadFailed", { message: errorMessage(err) }), "error");
      return false;
    }
    for (const path of rows.keys()) updatePath(path);
    shortcuts.onSettingsChanged();
    return true;
  }

  async function load() {
    els.content.replaceChildren(el(doc, "p", { class: "wmux-muted", text: t("settings.loading") }));
    try {
      await loadSchema();
      const result = await call("wmux.settings.get_effective", {});
      state.effective = normalizeEffective(result);
      if (result && result.files && typeof result.files === "object") state.files = result.files;
      state.loaded = true;
    } catch (err) {
      const retry = el(doc, "button", { type: "button", text: t("settings.retry") });
      retry.addEventListener("click", () => {
        load().then(() => render());
      });
      els.content.replaceChildren(
        el(doc, "p", {
          class: "set-load-error",
          role: "alert",
          text: t("settings.loadFailed", { message: errorMessage(err) }),
        }),
        retry,
      );
      return false;
    }
    return true;
  }

  /* ------------------------------------------------------------ sections */

  function fieldsIn(sectionId) {
    return state.fields.filter((f) => f.section === sectionId && !EDITOR_PATHS.has(f.path));
  }

  /** Sections shown in the nav: the fixed list plus unknown ids from the schema. */
  function sectionList() {
    const ids = SECTIONS.map((s) => s.id);
    for (const f of state.fields) if (!ids.includes(f.section)) ids.push(f.section);
    return ids;
  }

  function sectionMatches(id, tokens) {
    const sec = findSection(id);
    const hay = [sectionTitle(id), id, ...(sec ? sec.keywords : [])].join("\n");
    return tokens.length > 0 && matchesTokens(hay.normalize("NFKC").toLocaleLowerCase(), tokens);
  }

  function matchingFields(tokens) {
    return state.fields.filter((f) => {
      if (EDITOR_PATHS.has(f.path)) return false;
      const sec = findSection(f.section);
      return matchesTokens(fieldHaystack(f, sectionTitle(f.section), sec ? sec.keywords : []), tokens);
    });
  }

  function renderNav() {
    const tokens = queryTokens(state.query);
    const matched = tokens.length ? matchingFields(tokens) : [];
    els.navList.replaceChildren();
    for (const id of sectionList()) {
      const count = matched.filter((f) => f.section === id).length;
      const hit = tokens.length === 0 || count > 0 || sectionMatches(id, tokens);
      const button = el(doc, "button", { type: "button", class: "set-nav-item", "data-section": id });
      button.append(el(doc, "span", { class: "set-nav-label", text: sectionTitle(id) }));
      if (tokens.length && count > 0) button.append(el(doc, "span", { class: "set-nav-count", text: String(count) }));
      if (tokens.length === 0 && id === state.section) button.setAttribute("aria-current", "page");
      button.classList.toggle("set-nav-dim", !hit);
      button.addEventListener("click", () => {
        if (state.query) {
          state.query = "";
          els.search.value = "";
        }
        navigate(id);
      });
      els.navList.append(el(doc, "li", null, [button]));
    }
  }

  function heading(text, level) {
    return el(doc, level || "h1", { class: level === "h2" ? "set-subheading" : "set-heading", text });
  }

  function renderRowsInto(container, fields, tokens) {
    for (const f of fields) container.append(renderRow(f, tokens).element);
  }

  function renderSettingsJson(container) {
    const card = el(doc, "section", { class: "wmux-card set-card" });
    card.append(heading(t("settings.json.title"), "h2"), el(doc, "p", { text: t("settings.json.body") }));
    if (state.files && typeof state.files.wmux === "string")
      card.append(el(doc, "code", { class: "set-file-path", text: state.files.wmux }));
    const open = (file) => async () => {
      try {
        await call("wmux.settings.open_file", { file });
      } catch (err) {
        setStatus(t("settings.json.failed", { message: errorMessage(err) }), "error");
      }
    };
    const buttons = el(doc, "div", { class: "set-actions" });
    const openW = el(doc, "button", {
      type: "button",
      class: "wmux-primary",
      id: "set-open-json",
      text: t("settings.json.open"),
    });
    openW.addEventListener("click", open("wmux"));
    const openC = el(doc, "button", { type: "button", id: "set-open-cmux", text: t("settings.json.openCmux") });
    openC.addEventListener("click", open("cmux"));
    const docs = el(doc, "button", { type: "button", id: "set-open-docs", text: t("settings.json.docs") });
    docs.addEventListener("click", () => openDocs("settings"));
    buttons.append(openW, openC, docs);
    card.append(buttons);
    container.append(card);
  }

  async function openDocs(topic) {
    try {
      await call("wmux.settings.open_docs", { topic });
    } catch (err) {
      if (UNSUPPORTED_CODES.has(errorCode(err)) && state.docsUrl) {
        bridge.panel.openExternal(state.docsUrl).catch(() => {});
      } else {
        setStatus(t("settings.json.failed", { message: errorMessage(err) }), "error");
      }
    }
  }

  function renderReset(container) {
    const card = el(doc, "section", { class: "wmux-card set-card" });
    const button = el(doc, "button", {
      type: "button",
      id: "set-reset-all",
      class: "set-danger",
      text: t("settings.resetAll.button"),
    });
    button.addEventListener("click", () => resetAll());
    card.append(
      heading(t("settings.resetAll.title"), "h2"),
      el(doc, "p", { text: t("settings.resetAll.body") }),
      button,
    );
    container.append(card);
  }

  async function resetAll() {
    const ok = await confirm(t("settings.resetAll.confirm"), t("settings.resetAll.ok"));
    if (!ok) return false;
    try {
      try {
        await call("wmux.settings.reset_all", {});
      } catch (err) {
        if (!UNSUPPORTED_CODES.has(errorCode(err)) || errorCode(err) === "forbidden") throw err;
        // Fallback: unset every value this window can reset, one by one.
        for (const [path, entry] of state.effective) {
          if (entry.source === "wmux.json" && !entry.locked && state.byPath.has(path)) {
            await call("wmux.settings.unset", { path });
          }
        }
      }
      state.overridden.clear();
      await refreshEffective();
      setStatus(t("settings.resetAll.done"));
      return true;
    } catch (err) {
      await refreshEffective();
      setStatus(t("settings.resetAll.failed", { message: errorMessage(err) }), "error");
      return false;
    }
  }

  /* -------------------------------------------------------------- render */

  const shortcuts = createShortcutsView({ document: doc, call, keys, confirm, setStatus, renderRow, state, openDocs });
  const themes = createThemesView({ document: doc, call, setStatus });

  function renderSection(id) {
    const container = el(doc, "section", {
      class: "set-section",
      "data-section": id,
      "aria-labelledby": "set-section-title",
    });
    const title = heading(sectionTitle(id));
    title.id = "set-section-title";
    title.tabIndex = -1; // focus target after a search-result link
    container.append(title);
    const fields = fieldsIn(id);
    if (id === "themes") container.append(themes.render());
    if (id === "keyboardShortcuts") container.append(shortcuts.render());
    if (id === "settingsJSON") renderSettingsJson(container);
    if (id === "reset") renderReset(container);
    if (fields.length > 0) {
      const list = el(doc, "div", { class: "set-rows" });
      renderRowsInto(list, fields, []);
      container.append(list);
    } else if (!findSection(id) || !findSection(id).custom) {
      container.append(el(doc, "p", { class: "wmux-muted set-empty", text: t("settings.emptySection") }));
    }
    return container;
  }

  function renderSearch() {
    const tokens = queryTokens(state.query);
    const container = el(doc, "section", { class: "set-section set-search-results" });
    const matched = matchingFields(tokens);
    const customHits = sectionList().filter(
      (id) => findSection(id) && findSection(id).custom && sectionMatches(id, tokens),
    );
    if (matched.length === 0 && customHits.length === 0) {
      container.append(
        el(doc, "p", {
          class: "wmux-muted set-empty",
          text: t("settings.search.noResults", { query: state.query.trim() }),
        }),
      );
      return container;
    }
    container.append(
      el(doc, "p", {
        class: "wmux-muted set-result-count",
        text: t("settings.search.results", { count: matched.length }),
      }),
    );
    for (const id of sectionList()) {
      const fields = matched.filter((f) => f.section === id);
      const custom = customHits.includes(id);
      if (fields.length === 0 && !custom) continue;
      const group = el(doc, "div", { class: "set-result-group", "data-section": id });
      const link = el(doc, "button", { type: "button", class: "wmux-link set-result-section" });
      appendHighlighted(doc, link, sectionTitle(id), tokens);
      link.addEventListener("click", () => {
        state.query = "";
        els.search.value = "";
        navigate(id);
        // The link is gone after the re-render: continue at the section heading.
        const title = doc.getElementById("set-section-title");
        if (title) title.focus();
      });
      group.append(el(doc, "h2", { class: "set-subheading" }, [link]));
      if (fields.length) {
        const list = el(doc, "div", { class: "set-rows" });
        renderRowsInto(list, fields, tokens);
        group.append(list);
      }
      container.append(group);
    }
    return container;
  }

  function render() {
    if (!state.loaded) return;
    // A recorder must not outlive the row it records for.
    cancelRecorders();
    // The nav is rebuilt: keep keyboard focus on the same item (Enter on an
    // item must not drop focus to <body> and break arrow-key navigation).
    const active = doc.activeElement;
    const navFocus = active && els.navList.contains(active) && active.dataset ? active.dataset.section : null;
    for (const set of rows.values()) set.clear();
    renderNav();
    const view = queryTokens(state.query).length ? renderSearch() : renderSection(state.section);
    els.content.replaceChildren(view);
    if (navFocus) {
      const item = Array.from(els.navList.querySelectorAll(".set-nav-item")).find((b) => b.dataset.section === navFocus);
      if (item) item.focus();
    }
  }

  /** Show a section (raw id or CLI alias). Returns the section id shown. */
  function navigate(target) {
    const id = resolveTarget(target) || (sectionList().includes(target) ? target : null);
    if (!id) {
      if (typeof target === "string" && target.trim())
        setStatus(t("settings.unavailableTarget", { target: target.trim() }));
      if (state.loaded && !els.content.querySelector(".set-section")) render();
      return state.section;
    }
    state.section = id;
    shortcuts.stopRecording();
    render();
    if (els.main && typeof els.main.scrollTo === "function") els.main.scrollTo(0, 0);
    if (bridge.panel && typeof bridge.panel.setState === "function") {
      bridge.panel.setState({ v: 1, section: id }).catch(() => {});
    }
    return id;
  }

  function setQuery(query) {
    state.query = typeof query === "string" ? query.slice(0, 256) : "";
    if (els.search.value !== state.query) els.search.value = state.query;
    render();
  }

  /* --------------------------------------------------------------- start */

  function wireNav() {
    els.search.addEventListener("input", () => setQuery(els.search.value));
    els.search.addEventListener("keydown", (e) => {
      if (e.key === "Escape" && els.search.value) {
        e.preventDefault();
        setQuery("");
      }
    });
    els.navList.addEventListener("keydown", (e) => {
      if (e.key !== "ArrowDown" && e.key !== "ArrowUp" && e.key !== "Home" && e.key !== "End") return;
      const items = Array.from(els.navList.querySelectorAll(".set-nav-item"));
      const i = items.indexOf(doc.activeElement);
      if (i < 0 || items.length === 0) return;
      e.preventDefault();
      let next = i;
      if (e.key === "ArrowDown") next = (i + 1) % items.length;
      else if (e.key === "ArrowUp") next = (i - 1 + items.length) % items.length;
      else if (e.key === "Home") next = 0;
      else next = items.length - 1;
      items[next].focus();
    });
    const onKey = (e) => {
      if (e.defaultPrevented || shortcuts.isRecording()) return;
      if ((e.ctrlKey || e.metaKey) && !e.altKey && !e.shiftKey && (e.key === "f" || e.key === "F")) {
        e.preventDefault();
        els.search.focus();
        els.search.select();
      }
    };
    doc.addEventListener("keydown", onKey);
    cleanup.push(() => doc.removeEventListener("keydown", onKey));
  }

  function wireEvents() {
    const on = (event, fn) => cleanup.push(bridge.on(event, fn));
    on("wmux.settings.navigate", (payload) => {
      if (payload && typeof payload.target === "string") navigate(payload.target);
    });
    on("wmux.settings.changed", (payload) => {
      if (payload && payload.values) {
        for (const [path, entry] of normalizeEffective(payload)) state.effective.set(path, entry);
        for (const path of rows.keys()) updatePath(path);
        shortcuts.onSettingsChanged();
      } else {
        refreshEffective();
      }
    });
    on("wmux.settings.schema_changed", () => {
      loadSchema()
        .then(() => render())
        .catch(() => {});
    });
    on("wmux.settings.shortcuts_changed", () => shortcuts.reload());
    on("wmux.settings.themes_changed", () => themes.reload());
  }

  async function start() {
    applyStrings(doc);
    wireConfirm();
    wireNav();
    wireEvents();
    let ctx = null;
    try {
      ctx = await bridge.ready();
      // A reloaded host may push a newer panel.init than the first one.
      if (bridge.context) ctx = bridge.context;
    } catch (err) {
      els.content.replaceChildren(
        el(doc, "p", {
          class: "set-load-error",
          role: "alert",
          text: t("settings.loadFailed", { message: errorMessage(err) }),
        }),
      );
      return false;
    }
    if (bridge.panel && typeof bridge.panel.setTitle === "function")
      bridge.panel.setTitle(t("settings.title")).catch(() => {});
    const params = (ctx && ctx.params) || {};
    const saved = ctx && ctx.state && typeof ctx.state.section === "string" ? ctx.state.section : null;
    const target = typeof params.target === "string" && params.target ? params.target : saved;
    if (!(await load())) return false;
    const initial = resolveTarget(target) || (target && sectionList().includes(target) ? target : null);
    if (initial) state.section = initial;
    else if (target) setStatus(t("settings.unavailableTarget", { target }));
    if (typeof params.query === "string" && params.query) state.query = params.query.slice(0, 256);
    els.search.value = state.query;
    render();
    return true;
  }

  function destroy() {
    shortcuts.stopRecording();
    cancelRecorders();
    closeConfirm(false);
    if (statusTimer) clearTimeout(statusTimer);
    statusTimer = null;
    for (const fn of cleanup.splice(0)) {
      if (typeof fn === "function") fn();
    }
  }

  return {
    start,
    destroy,
    state,
    navigate,
    setQuery,
    render,
    refreshEffective,
    resetAll,
    confirm,
    closeConfirm,
    shortcuts,
    themes,
    rowsFor: (path) => Array.from(rows.get(path) || []).filter((r) => r.element.isConnected),
  };
}
