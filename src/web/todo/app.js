/**
 * Todos pane application: PanelKind "todo" (ARCHITECTURE ADR-6.11), entry
 * https://todo.wmux.example/todo/index.html. One workspace's full checklist:
 * header (status glyph, title, lane, progress), items (not completed first),
 * a pinned always-armed add row, keyboard highlight and toggle, click to
 * edit, context menu, image attachments, drag reorder within a completion
 * group and live updates. The native contract is documented in README.md.
 *
 *   const app = createApp({ document });
 *   await app.start();
 *
 * The document, bridge and key layer are injectable so the jsdom tests in
 * test/web-node/todo/ drive the real code.
 */
import { wmux as defaultBridge } from "../_shared/wmux-bridge.js";
import { installKeys } from "../_shared/keys.js";
import { applyStrings } from "../_shared/strings.js";
import {
  MAX_ITEMS,
  applyMove,
  displayOrder,
  dropTarget,
  keepHighlight,
  laneLabel,
  normalizeList,
  normalizeText,
  progress,
  progressText,
  stepTarget,
  toggledState,
} from "./model.js";
import { attachmentsLabel, t } from "./strings.js";

/** Default binding of the cmux action (Ctrl+Enter on Windows, ADR-8 table). */
export const DEFAULT_KEYMAP = Object.freeze({ toggleChecklistItemComplete: ["ctrl+enter"] });
/** Error codes meaning the workspace no longer exists. */
const GONE_CODES = new Set(["not_found", "workspace_not_found"]);
const ERROR_MS = 4000;

function errorMessage(err) {
  return err && typeof err.message === "string" ? err.message : String(err);
}

function errorCode(err) {
  return err && typeof err.code === "string" ? err.code : "";
}

/** Workspace id carried by a `cmux.event` frame (top level, payload or data). */
function frameWorkspaceId(frame) {
  if (!frame || typeof frame !== "object") return null;
  for (const src of [frame, frame.payload, frame.data]) {
    if (src && typeof src === "object" && typeof src.workspace_id === "string") return src.workspace_id;
  }
  return null;
}

function frameName(frame) {
  if (!frame || typeof frame !== "object") return "";
  if (typeof frame.name === "string") return frame.name;
  if (typeof frame.event === "string") return frame.event;
  return "";
}

/**
 * @param {{
 *   document: Document,
 *   bridge?: typeof defaultBridge,
 *   installKeys?: Function,
 *   readyTimeoutMs?: number,
 * }} options
 */
export function createApp(options) {
  const doc = options.document;
  const bridge = options.bridge || defaultBridge;
  const $ = (id) => doc.getElementById(id);
  const ui = {
    status: $("todo-status"),
    lane: $("todo-lane"),
    progress: $("todo-progress"),
    clear: $("todo-clear"),
    error: $("todo-error"),
    main: $("todo-main"),
    list: $("todo-list"),
    empty: $("todo-empty"),
    unavailable: $("todo-unavailable"),
    add: $("todo-add"),
    addInput: $("todo-add-input"),
    menu: $("todo-menu"),
    confirm: $("todo-confirm"),
    confirmText: $("todo-confirm-text"),
    confirmOk: $("todo-confirm-ok"),
    confirmCancel: $("todo-confirm-cancel"),
  };

  const state = {
    started: false,
    destroyed: false,
    workspaceId: null,
    loaded: false,
    available: true,
    items: [],
    highlightId: null,
    editingId: null,
    status: null,
    drag: null,
    menuFor: null,
    confirmResolve: null,
    loadSeq: 0,
    rendering: false,
  };
  const cleanups = [];
  const timers = new Set();
  let errorTimer = null;

  function later(fn, ms) {
    const id = setTimeout(() => {
      timers.delete(id);
      fn();
    }, ms);
    timers.add(id);
    return id;
  }

  function cancel(id) {
    if (id === null || id === undefined) return;
    clearTimeout(id);
    timers.delete(id);
  }

  function listen(target, type, fn, opts) {
    target.addEventListener(type, fn, opts);
    cleanups.push(() => target.removeEventListener(type, fn, opts));
  }

  function showError(text) {
    ui.error.textContent = text;
    ui.error.hidden = !text;
    cancel(errorTimer);
    errorTimer = text ? later(() => showError(""), ERROR_MS) : null;
  }

  function itemById(id) {
    return state.items.find((it) => it.id === id) || null;
  }

  function withWorkspace(params) {
    return state.workspaceId ? { workspace_id: state.workspaceId, ...params } : params;
  }

  /* ---------------------------------------------------------------------- */
  /* rendering                                                              */
  /* ---------------------------------------------------------------------- */

  function renderHeader() {
    const p = progress(state.items);
    ui.progress.textContent = state.available && p.total > 0 ? progressText(p) : "";
    ui.progress.title = t("todo.progress", p);
    ui.clear.hidden = !state.available || p.total === 0;
    const lane = state.available ? laneLabel(state.status) : "";
    ui.lane.textContent = lane;
    ui.lane.hidden = !lane;
    const rawLane = state.status && (state.status.lane || state.status.status);
    if (typeof rawLane === "string" && rawLane) ui.status.dataset.lane = rawLane;
    else delete ui.status.dataset.lane;
    ui.status.hidden = !state.available;
  }

  function attachButton(item) {
    const btn = doc.createElement("button");
    btn.type = "button";
    btn.className = "todo-attach";
    btn.dataset.action = "attachments";
    btn.title = t("todo.attach.tip");
    btn.setAttribute("aria-label", attachmentsLabel(item.attachments.length));
    btn.setAttribute("aria-haspopup", "menu");
    const icon = doc.createElement("span");
    icon.className = "todo-attach-icon";
    icon.setAttribute("aria-hidden", "true");
    btn.append(icon);
    if (item.attachments.length) {
      const count = doc.createElement("span");
      count.className = "todo-attach-count";
      count.textContent = String(item.attachments.length);
      btn.append(count);
    }
    return btn;
  }

  function renderItem(item, pos) {
    const li = doc.createElement("li");
    li.className = "todo-item";
    li.id = `todo-item-${pos}`;
    li.dataset.id = item.id;
    li.setAttribute("role", "option");
    li.draggable = state.editingId !== item.id;
    const done = item.state === "completed";
    li.classList.toggle("is-completed", done);
    li.classList.toggle("is-in-progress", item.state === "in-progress");
    li.classList.toggle("is-highlighted", state.highlightId === item.id);
    li.setAttribute("aria-selected", state.highlightId === item.id ? "true" : "false");
    // The row is what the keyboard moves over (aria-activedescendant); its
    // checkbox is out of the Tab order, so the option itself carries the state.
    li.setAttribute("aria-checked", done ? "true" : "false");

    const box = doc.createElement("input");
    box.type = "checkbox";
    box.className = "todo-check";
    box.tabIndex = -1;
    box.checked = done;
    box.indeterminate = item.state === "in-progress";
    const tip = done ? t("todo.uncheck") : t("todo.check");
    box.title = tip;
    box.setAttribute("aria-label", tip);
    li.append(box);

    if (state.editingId === item.id) {
      const editor = doc.createElement("input");
      editor.type = "text";
      editor.className = "todo-editor";
      editor.value = item.text;
      editor.placeholder = t("todo.edit.label");
      editor.setAttribute("aria-label", t("todo.edit.label"));
      li.append(editor);
    } else {
      const text = doc.createElement("span");
      text.className = "todo-text";
      text.textContent = item.text;
      li.append(text);
    }
    if (item.state === "in-progress") {
      const badge = doc.createElement("span");
      badge.className = "todo-badge todo-badge-progress";
      badge.textContent = t("todo.inProgress");
      li.append(badge);
    }
    if (item.origin === "agent") {
      const badge = doc.createElement("span");
      badge.className = "todo-badge todo-badge-agent";
      badge.textContent = t("todo.agent");
      badge.title = t("todo.agentTip");
      li.append(badge);
    }
    li.append(attachButton(item));
    return li;
  }

  function render() {
    const editor = ui.list.querySelector(".todo-editor");
    const draft = editor
      ? { value: editor.value, start: editor.selectionStart, end: editor.selectionEnd }
      : null;
    const focused = doc.activeElement;
    const hadFocus = editor && focused === editor;
    // Focus on the list or inside it (the editor, a clicked checkbox).
    const listHadFocus = Boolean(focused) && ui.list.contains(focused);
    if (state.editingId && !itemById(state.editingId)) state.editingId = null;

    // Chromium (WebView2) fires focusout, relatedTarget null, while
    // replaceChildren() removes the focused editor; onEditorBlur must not take
    // that for the user leaving the editor.
    state.rendering = true;
    try {
      ui.list.replaceChildren();
      const order = displayOrder(state.items);
      order.forEach((index, pos) => ui.list.append(renderItem(state.items[index], pos)));
    } finally {
      state.rendering = false;
    }
    const active = ui.list.querySelector(".todo-item.is-highlighted");
    if (active) ui.list.setAttribute("aria-activedescendant", active.id);
    else ui.list.removeAttribute("aria-activedescendant");

    ui.main.hidden = !state.available;
    ui.add.hidden = !state.available;
    ui.unavailable.hidden = state.available;
    ui.empty.hidden = !state.available || !state.loaded || state.items.length > 0;
    renderHeader();

    const next = ui.list.querySelector(".todo-editor");
    if (next && draft) {
      next.value = draft.value;
      if (hadFocus) {
        next.focus();
        try {
          next.setSelectionRange(draft.start, draft.end);
        } catch {
          // ignore
        }
      }
    }
    // Removing a focused child (a checkbox WebView2 focused on click, the editor
    // of an item that went away) drops focus to <body>; keep it on the list.
    if (listHadFocus && state.available && !ui.list.contains(doc.activeElement)) ui.list.focus();
  }

  function scrollHighlightIntoView() {
    const el = ui.list.querySelector(".todo-item.is-highlighted");
    if (el && typeof el.scrollIntoView === "function") el.scrollIntoView({ block: "nearest" });
  }

  /* ---------------------------------------------------------------------- */
  /* data                                                                   */
  /* ---------------------------------------------------------------------- */

  function setUnavailable() {
    state.available = false;
    state.editingId = null;
    closeMenu();
    render();
  }

  /** Apply a checklist payload; false when it is not one. */
  function applyList(payload) {
    const list = normalizeList(payload);
    if (!list) return false;
    const order = displayOrder(state.items);
    const prevPos = order.findIndex((i) => state.items[i].id === state.highlightId);
    state.items = list.items;
    state.highlightId = keepHighlight(state.items, state.highlightId, prevPos < 0 ? null : prevPos);
    state.loaded = true;
    state.available = true;
    render();
    return true;
  }

  async function refresh() {
    const seq = ++state.loadSeq;
    try {
      const result = await bridge.call("workspace.todo.list", withWorkspace({}));
      if (state.destroyed || seq !== state.loadSeq) return;
      if (!applyList(result)) showError(t("todo.error.load", { message: t("todo.error.malformed") }));
    } catch (err) {
      if (state.destroyed || seq !== state.loadSeq) return;
      if (GONE_CODES.has(errorCode(err))) setUnavailable();
      else showError(t("todo.error.load", { message: errorMessage(err) }));
    }
  }

  async function loadStatus() {
    try {
      const result = await bridge.call("workspace.status.get", withWorkspace({}));
      if (state.destroyed) return;
      state.status = result && typeof result === "object" ? result : null;
      renderHeader();
    } catch {
      // Status lanes are optional: the glyph stays neutral.
    }
  }

  /**
   * Run a checklist mutation. `optimistic` updates the local list first; on
   * failure the list is re-read. A reply carrying the checklist is applied,
   * otherwise the list is re-read.
   */
  async function mutate(method, params, optimistic) {
    if (!state.available) return false;
    if (optimistic) {
      state.items = optimistic(state.items);
      render();
    }
    // Writes supersede any list read still in flight.
    state.loadSeq += 1;
    try {
      const result = await bridge.call(method, withWorkspace(params));
      if (state.destroyed) return true;
      if (!applyList(result)) await refresh();
      return true;
    } catch (err) {
      if (state.destroyed) return false;
      // not_found can name the item (an agent or the CLI removed it meanwhile)
      // as well as the workspace: the re-read switches to the unavailable state
      // only when the workspace itself is gone.
      showError(t("todo.error.failed", { message: errorMessage(err) }));
      await refresh();
      return false;
    }
  }

  function replaceItem(id, patch) {
    return (items) => items.map((it) => (it.id === id ? { ...it, ...patch } : it));
  }

  async function addItem(raw) {
    const norm = normalizeText(raw);
    if (!norm.ok) {
      showError(t(norm.error === "empty" ? "todo.error.empty" : "todo.error.invalid"));
      return false;
    }
    if (state.items.length >= MAX_ITEMS) {
      showError(t("todo.error.full", { max: MAX_ITEMS }));
      return false;
    }
    return mutate("workspace.todo.add", { text: norm.text });
  }

  function setItemState(id, next) {
    const item = itemById(id);
    if (!item || item.state === next) return Promise.resolve(false);
    return mutate("workspace.todo.set_state", { item: id, state: next }, replaceItem(id, { state: next }));
  }

  function toggleItem(id) {
    const item = itemById(id);
    if (!item) return Promise.resolve(false);
    return setItemState(id, toggledState(item.state));
  }

  async function editItem(id, raw) {
    const item = itemById(id);
    if (!item) return false;
    const norm = normalizeText(raw);
    if (!norm.ok) {
      showError(t(norm.error === "empty" ? "todo.error.empty" : "todo.error.invalid"));
      return false;
    }
    if (norm.text === item.text) return true;
    return mutate("workspace.todo.edit", { item: id, text: norm.text }, replaceItem(id, { text: norm.text }));
  }

  function removeItem(id) {
    if (!itemById(id)) return Promise.resolve(false);
    if (state.editingId === id) state.editingId = null;
    return mutate("workspace.todo.remove", { item: id }, (items) => items.filter((it) => it.id !== id));
  }

  /** Move to storage index `dest` (already clamped to the item's group). */
  function moveItem(id, dest) {
    const from = state.items.findIndex((it) => it.id === id);
    if (from < 0 || dest === null || dest === from) return Promise.resolve(false);
    return mutate("workspace.todo.move", { item: id, index: dest }, (items) => applyMove(items, from, dest));
  }

  async function clearAll() {
    if (!state.items.length) return false;
    const ok = await confirm(t("todo.clear.confirm", { total: state.items.length }));
    if (!ok) return false;
    state.editingId = null;
    // The Clear button hides with the last item: keep the keyboard in the add row.
    if (state.available) ui.addInput.focus();
    return mutate("workspace.todo.clear", {}, () => []);
  }

  async function attachImages(id) {
    try {
      const result = await bridge.call("panel.todo.attach_images", withWorkspace({ item: id }), {
        timeoutMs: 0,
      });
      if (!applyList(result)) await refresh();
    } catch (err) {
      if (errorCode(err) !== "cancelled") showError(t("todo.error.failed", { message: errorMessage(err) }));
    }
  }

  function openAttachment(id, attachmentId) {
    bridge
      .call("panel.todo.open_attachment", withWorkspace({ item: id, attachment: attachmentId }))
      .catch((err) => {
        showError(t("todo.error.failed", { message: errorMessage(err) }));
      });
  }

  function removeAttachment(id, attachmentId) {
    return mutate(
      "panel.todo.remove_attachment",
      { item: id, attachment: attachmentId },
      replaceItem(id, {
        attachments: (itemById(id) || { attachments: [] }).attachments.filter((a) => a.id !== attachmentId),
      }),
    );
  }

  /* ---------------------------------------------------------------------- */
  /* selection and editing                                                  */
  /* ---------------------------------------------------------------------- */

  function highlight(id, scroll) {
    state.highlightId = id;
    render();
    if (scroll) scrollHighlightIntoView();
  }

  function moveHighlight(delta) {
    const order = displayOrder(state.items);
    if (!order.length) return;
    const pos = order.findIndex((i) => state.items[i].id === state.highlightId);
    let next;
    if (pos < 0) next = delta > 0 ? 0 : order.length - 1;
    else next = Math.min(Math.max(pos + delta, 0), order.length - 1);
    highlight(state.items[order[next]].id, true);
  }

  function startEdit(id) {
    if (!itemById(id) || !state.available) return;
    state.highlightId = id;
    state.editingId = id;
    render();
    const editor = ui.list.querySelector(".todo-editor");
    if (editor) {
      editor.focus();
      editor.select();
    }
  }

  /** Commit (or with `keep = false` discard) the open editor. */
  async function finishEdit(keep) {
    const id = state.editingId;
    if (!id) return;
    const editor = ui.list.querySelector(".todo-editor");
    const value = editor ? editor.value : "";
    state.editingId = null;
    render();
    ui.list.focus();
    if (keep) await editItem(id, value);
  }

  /* ---------------------------------------------------------------------- */
  /* menus and confirmation                                                 */
  /* ---------------------------------------------------------------------- */

  function menuButton(label, action, extra) {
    const btn = doc.createElement("button");
    btn.type = "button";
    btn.className = "todo-menu-item";
    btn.setAttribute("role", "menuitem");
    btn.tabIndex = -1;
    btn.dataset.action = action;
    if (extra) btn.dataset.attachment = extra;
    btn.textContent = label;
    return btn;
  }

  function menuSeparator() {
    const sep = doc.createElement("div");
    sep.className = "todo-menu-separator";
    sep.setAttribute("role", "separator");
    return sep;
  }

  function contextEntries(item) {
    const start =
      item.state === "in-progress"
        ? menuButton(t("todo.menu.pending"), "pending")
        : menuButton(t("todo.menu.start"), "start");
    return [menuButton(t("todo.menu.edit"), "edit"), start, menuButton(t("todo.menu.remove"), "remove")];
  }

  function attachmentEntries(item) {
    const out = [menuButton(t("todo.menu.attach"), "attach")];
    for (const att of item.attachments) {
      out.push(menuSeparator());
      const label = doc.createElement("div");
      label.className = "todo-menu-label";
      label.setAttribute("role", "presentation");
      label.textContent = att.name;
      out.push(label);
      out.push(menuButton(t("todo.menu.open"), "open-attachment", att.id));
      out.push(menuButton(t("todo.menu.removeAttachment"), "remove-attachment", att.id));
    }
    return out;
  }

  function openMenu(item, kind, x, y) {
    state.menuFor = item.id;
    ui.menu.replaceChildren(...(kind === "attachments" ? attachmentEntries(item) : contextEntries(item)));
    ui.menu.hidden = false;
    const view = doc.defaultView;
    const maxX = Math.max(0, (view ? view.innerWidth : 0) - (ui.menu.offsetWidth || 180));
    const maxY = Math.max(0, (view ? view.innerHeight : 0) - (ui.menu.offsetHeight || 120));
    ui.menu.style.setProperty("left", `${Math.max(0, Math.min(x, maxX))}px`);
    ui.menu.style.setProperty("top", `${Math.max(0, Math.min(y, maxY))}px`);
    const first = ui.menu.querySelector(".todo-menu-item");
    if (first) first.focus();
  }

  function closeMenu() {
    if (ui.menu.hidden) return;
    ui.menu.hidden = true;
    ui.menu.replaceChildren();
    state.menuFor = null;
  }

  function runMenuAction(btn) {
    const id = state.menuFor;
    const action = btn.dataset.action;
    const attachment = btn.dataset.attachment;
    closeMenu();
    if (!id || !itemById(id)) return;
    if (action === "edit") startEdit(id);
    else if (action === "start") setItemState(id, "in-progress");
    else if (action === "pending") setItemState(id, "pending");
    else if (action === "remove") removeItem(id);
    else if (action === "attach") attachImages(id);
    else if (action === "open-attachment") openAttachment(id, attachment);
    else if (action === "remove-attachment") removeAttachment(id, attachment);
    if (action !== "edit") ui.list.focus();
  }

  function menuKey(e) {
    const items = Array.from(ui.menu.querySelectorAll(".todo-menu-item"));
    const pos = items.indexOf(doc.activeElement);
    if (e.key === "Escape") {
      closeMenu();
      ui.list.focus();
    } else if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      const step = e.key === "ArrowDown" ? 1 : -1;
      const next = items[(pos + step + items.length) % items.length];
      if (next) next.focus();
    } else if (e.key === "Home" || e.key === "End") {
      const next = e.key === "Home" ? items[0] : items[items.length - 1];
      if (next) next.focus();
    } else {
      return;
    }
    e.preventDefault();
    e.stopPropagation();
  }

  /** aria-modal: keep focus and the screen reader inside the open confirmation. */
  function setBackgroundInert(on) {
    for (const el of Array.from(doc.body.children)) if (el !== ui.confirm) el.toggleAttribute("inert", on);
  }

  function confirm(text) {
    if (state.confirmResolve) state.confirmResolve(false);
    const opener = doc.activeElement;
    ui.confirmText.textContent = text;
    ui.confirm.hidden = false;
    setBackgroundInert(true);
    ui.confirmCancel.focus();
    return new Promise((resolve) => {
      state.confirmResolve = (ok) => {
        state.confirmResolve = null;
        ui.confirm.hidden = true;
        setBackgroundInert(false);
        // Hand focus back to what opened the dialog (not <body>).
        if (!state.destroyed) {
          const back = opener && opener !== doc.body && opener.isConnected && !opener.closest("[hidden]");
          if (back) opener.focus();
          else if (state.available) ui.list.focus();
        }
        resolve(ok);
      };
    });
  }

  /* ---------------------------------------------------------------------- */
  /* DOM wiring                                                             */
  /* ---------------------------------------------------------------------- */

  function itemOf(target) {
    const li = target && typeof target.closest === "function" ? target.closest(".todo-item") : null;
    return li && ui.list.contains(li) ? li : null;
  }

  function onListClick(e) {
    const li = itemOf(e.target);
    if (!li) return;
    const id = li.dataset.id;
    if (e.target.closest(".todo-check")) {
      toggleItem(id);
      return;
    }
    if (e.target.closest(".todo-attach")) {
      const item = itemById(id);
      const r = e.target.closest(".todo-attach").getBoundingClientRect();
      if (item) openMenu(item, "attachments", r.left, r.bottom);
      return;
    }
    if (e.target.closest(".todo-editor")) return;
    if (state.editingId === id) {
      const editor = ui.list.querySelector(".todo-editor");
      if (editor) editor.focus();
      return;
    }
    if (state.editingId) {
      finishEdit(true);
      highlight(id);
      return;
    }
    if (state.highlightId === id) startEdit(id);
    else {
      highlight(id);
      ui.list.focus();
    }
  }

  function onContextMenu(e) {
    e.preventDefault();
    const li = itemOf(e.target);
    if (!li || e.target.closest(".todo-editor")) return;
    const item = itemById(li.dataset.id);
    if (!item) return;
    if (state.editingId && state.editingId !== item.id) finishEdit(true);
    highlight(item.id);
    openMenu(item, "context", e.clientX, e.clientY);
  }

  function openContextForHighlight() {
    const item = itemById(state.highlightId);
    const li = ui.list.querySelector(".todo-item.is-highlighted");
    if (!item || !li) return;
    const r = li.getBoundingClientRect();
    openMenu(item, "context", r.left + 16, r.bottom);
  }

  function onListKey(e) {
    if (e.target.closest && e.target.closest(".todo-editor")) {
      if (e.key === "Enter" && !e.isComposing && !e.ctrlKey && !e.altKey && !e.metaKey) {
        e.preventDefault();
        finishEdit(true);
      } else if (e.key === "Escape") {
        e.preventDefault();
        e.stopPropagation();
        finishEdit(false);
      }
      return;
    }
    const plain = !e.ctrlKey && !e.altKey && !e.metaKey && !e.shiftKey;
    // A button inside a row (the paperclip) keeps Return for its own activation.
    const onButton = e.target !== ui.list && Boolean(e.target.closest && e.target.closest("button"));
    if ((e.key === "ArrowDown" || e.key === "ArrowUp") && plain) {
      moveHighlight(e.key === "ArrowDown" ? 1 : -1);
    } else if ((e.key === "ArrowDown" || e.key === "ArrowUp") && e.altKey && !e.ctrlKey && !e.metaKey) {
      if (state.highlightId)
        moveItem(
          state.highlightId,
          stepTarget(state.items, state.highlightId, e.key === "ArrowDown" ? 1 : -1),
        );
    } else if ((e.key === "Home" || e.key === "End") && plain) {
      const order = displayOrder(state.items);
      if (order.length) highlight(state.items[order[e.key === "Home" ? 0 : order.length - 1]].id, true);
    } else if (e.key === "Enter" && plain && !e.isComposing) {
      if (onButton) return;
      if (state.highlightId) toggleItem(state.highlightId);
    } else if (e.key === "F2" && plain) {
      if (state.highlightId) startEdit(state.highlightId);
    } else if (e.key === "ContextMenu" || (e.key === "F10" && e.shiftKey && !e.ctrlKey && !e.altKey)) {
      openContextForHighlight();
    } else {
      return;
    }
    e.preventDefault();
  }

  function onEditorBlur(e) {
    // A re-render replacing the editor is not the user leaving it (render() keeps the draft).
    if (state.rendering) return;
    if (e.target.classList && e.target.classList.contains("todo-editor") && state.editingId) {
      // Clicking a menu or the list keeps the edit open; leaving the pane commits it.
      const next = e.relatedTarget;
      if (next && (ui.list.contains(next) || ui.menu.contains(next))) return;
      finishEdit(true);
    }
  }

  function clearDropMarks() {
    for (const el of ui.list.querySelectorAll(".drop-before, .drop-after")) {
      el.classList.remove("drop-before", "drop-after");
    }
  }

  function dropInfo(e) {
    const li = itemOf(e.target);
    if (!li || !state.drag) return null;
    const r = li.getBoundingClientRect();
    const after = r.height > 0 && e.clientY > r.top + r.height / 2;
    const dest = dropTarget(state.items, state.drag, li.dataset.id, after);
    return dest === null ? null : { li, after, dest };
  }

  function onDragStart(e) {
    const li = itemOf(e.target);
    if (!li || state.editingId === li.dataset.id) return;
    state.drag = li.dataset.id;
    li.classList.add("is-dragging");
    if (e.dataTransfer) {
      e.dataTransfer.effectAllowed = "move";
      try {
        e.dataTransfer.setData("text/plain", li.dataset.id);
      } catch {
        // ignore
      }
    }
  }

  function onDragOver(e) {
    const info = dropInfo(e);
    clearDropMarks();
    if (!info) return;
    e.preventDefault();
    if (e.dataTransfer) e.dataTransfer.dropEffect = "move";
    info.li.classList.add(info.after ? "drop-after" : "drop-before");
  }

  function onDrop(e) {
    const info = dropInfo(e);
    const id = state.drag;
    onDragEnd();
    if (!info) return;
    e.preventDefault();
    moveItem(id, info.dest);
  }

  function onDragEnd() {
    clearDropMarks();
    for (const el of ui.list.querySelectorAll(".is-dragging")) el.classList.remove("is-dragging");
    state.drag = null;
  }

  function onAddKey(e) {
    // The add row stays armed (focused) after open and after each add, yet
    // Up/Down still move the list highlight there, so "Down, then Ctrl+Enter"
    // completes an item without leaving the field.
    if (
      (e.key === "ArrowDown" || e.key === "ArrowUp") &&
      !e.isComposing &&
      !e.ctrlKey &&
      !e.altKey &&
      !e.metaKey &&
      !e.shiftKey
    ) {
      e.preventDefault();
      moveHighlight(e.key === "ArrowDown" ? 1 : -1);
      return;
    }
    if (e.key !== "Enter" || e.isComposing || e.ctrlKey || e.altKey || e.metaKey) return;
    e.preventDefault();
    const value = ui.addInput.value;
    addItem(value).then((ok) => {
      if (ok && ui.addInput.value === value) ui.addInput.value = "";
    });
  }

  function focusAdd() {
    if (!state.available) return;
    if (state.editingId) finishEdit(true);
    ui.addInput.focus();
  }

  function openStatus() {
    const r = ui.status.getBoundingClientRect();
    const anchor = { x: r.left, y: r.top, width: r.width, height: r.height };
    bridge.call("panel.todo.open_status", withWorkspace({ anchor })).catch((err) => {
      console.warn("[todo] panel.todo.open_status failed:", errorMessage(err));
    });
  }

  function wireDom() {
    listen(ui.list, "click", onListClick);
    listen(ui.list, "contextmenu", onContextMenu);
    listen(ui.list, "keydown", onListKey);
    listen(ui.list, "focusout", onEditorBlur);
    listen(ui.list, "dragstart", onDragStart);
    listen(ui.list, "dragover", onDragOver);
    listen(ui.list, "drop", onDrop);
    listen(ui.list, "dragend", onDragEnd);
    listen(ui.addInput, "keydown", onAddKey);
    listen(ui.status, "click", openStatus);
    listen(ui.clear, "click", () => clearAll());
    listen(ui.menu, "click", (e) => {
      const btn = e.target.closest(".todo-menu-item");
      if (btn) runMenuAction(btn);
    });
    listen(ui.menu, "keydown", menuKey);
    listen(ui.confirmOk, "click", () => state.confirmResolve && state.confirmResolve(true));
    listen(ui.confirmCancel, "click", () => state.confirmResolve && state.confirmResolve(false));
    listen(ui.confirm, "keydown", (e) => {
      if (e.key === "Escape" && state.confirmResolve) {
        e.preventDefault();
        e.stopPropagation();
        state.confirmResolve(false);
      }
    });
    listen(doc, "mousedown", (e) => {
      if (!ui.menu.hidden && !ui.menu.contains(e.target)) closeMenu();
    });
    // Native context menus are off in panels (ADR-6.7); only the list draws one.
    listen(doc, "contextmenu", (e) => e.preventDefault());
  }

  function forThisWorkspace(payload) {
    if (!payload || typeof payload !== "object" || !state.workspaceId) return true;
    return typeof payload.workspace_id !== "string" || payload.workspace_id === state.workspaceId;
  }

  function wireBridge() {
    const on = (event, fn) => cleanups.push(bridge.on(event, fn));
    on("panel.todo.changed", (payload) => {
      if (!forThisWorkspace(payload)) return;
      if (!applyList(payload)) refresh();
    });
    on("panel.todo.status", (payload) => {
      if (!forThisWorkspace(payload)) return;
      state.status = payload && typeof payload === "object" ? payload : null;
      renderHeader();
    });
    on("panel.todo.focus_add", (payload) => {
      if (forThisWorkspace(payload)) focusAdd();
    });
    on("panel.todo.workspace_closed", (payload) => {
      if (forThisWorkspace(payload)) setUnavailable();
    });
    on("panel.todo.command", (payload) => {
      if (payload && typeof payload.action === "string") runAction(payload.action);
    });
    on("cmux.event", (frame) => {
      if (frameName(frame) !== "workspace.closed") return;
      const id = frameWorkspaceId(frame);
      if (id && state.workspaceId && id === state.workspaceId) setUnavailable();
    });
  }

  /** Actions native can send (palette, KeyRouter) or the page key layer runs. */
  function runAction(action) {
    if (action === "toggleChecklistItemComplete") {
      const id = state.editingId || state.highlightId;
      if (!id) return false;
      if (state.editingId) finishEdit(true);
      toggleItem(id);
      return true;
    }
    if (action === "wmux.todoFocusAdd") {
      focusAdd();
      return true;
    }
    return false;
  }

  function installKeyboard() {
    const keys = (options.installKeys || installKeys)();
    keys.setKeymap(DEFAULT_KEYMAP);
    if (bridge.context && bridge.context.keymap !== undefined) keys.setKeymap(bridge.context.keymap);
    cleanups.push(keys.handle("toggleChecklistItemComplete", () => runAction("toggleChecklistItemComplete")));
    return keys;
  }

  /* ---------------------------------------------------------------------- */
  /* start                                                                  */
  /* ---------------------------------------------------------------------- */

  async function start() {
    if (state.started) return api;
    state.started = true;
    applyStrings(doc);
    wireDom();
    wireBridge();
    const keys = installKeyboard();
    render();

    if (!bridge.available) {
      state.loaded = true;
      render();
      ui.error.textContent = t("todo.offline");
      ui.error.hidden = false;
      return api;
    }

    let ctx = null;
    try {
      ctx = await bridge.ready(
        options.readyTimeoutMs !== undefined ? { timeoutMs: options.readyTimeoutMs } : undefined,
      );
    } catch (err) {
      console.warn("[todo] panel.ready failed:", errorMessage(err));
    }
    if (state.destroyed) return api;
    if (bridge.context) ctx = bridge.context;
    if (ctx && ctx.keymap !== undefined) keys.setKeymap(ctx.keymap);
    const params = ctx && ctx.params && typeof ctx.params === "object" ? ctx.params : {};
    state.workspaceId =
      typeof params.workspace_id === "string" && params.workspace_id ? params.workspace_id : null;

    doc.title = t("todo.title");
    bridge.panel.setTitle(t("todo.title")).catch(() => {});
    bridge.panel.subscribe(["workspace"]).catch(() => {});

    if (params.workspace_missing === true) {
      setUnavailable();
      return api;
    }
    await refresh();
    loadStatus();
    if (params.focus_add !== false) focusAdd();
    return api;
  }

  function destroy() {
    state.destroyed = true;
    if (state.confirmResolve) state.confirmResolve(false);
    for (const fn of cleanups.splice(0)) {
      try {
        fn();
      } catch {
        // ignore
      }
    }
    for (const id of Array.from(timers)) cancel(id);
  }

  const api = {
    start,
    destroy,
    refresh,
    addItem,
    toggleItem,
    setItemState,
    editItem,
    removeItem,
    moveItem,
    clearAll,
    startEdit,
    finishEdit,
    focusAdd,
    runAction,
    get items() {
      return state.items.slice();
    },
    get highlightId() {
      return state.highlightId;
    },
    get editingId() {
      return state.editingId;
    },
    get available() {
      return state.available;
    },
    get workspaceId() {
      return state.workspaceId;
    },
  };
  return api;
}
