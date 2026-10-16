/**
 * Notifications panel application: PanelKind "notifications" (ARCHITECTURE
 * ADR-6.11, ADR-7.7), entry
 * https://notifications.wmux.example/notifications/index.html. The same page
 * runs in the popover (owned popup at the sidebar bell) and as a pane tab;
 * `panel.init.params.placement` picks the layout. The native contract is
 * documented in README.md.
 *
 *   const app = createApp({ document });
 *   await app.start();
 *
 * Everything is injectable (document, bridge, clock, keys) so the jsdom tests
 * in test/web-node/notifications/ drive the real code.
 */
import { wmux as defaultBridge } from "../_shared/wmux-bridge.js";
import { installKeys } from "../_shared/keys.js";
import { applyStrings } from "../_shared/strings.js";
import {
  bodyState,
  copyText,
  formatFullTime,
  formatShortTime,
  frameName,
  groupRecords,
  isRecordEvent,
  isWorkspaceEvent,
  markerCountFrom,
  recordsFrom,
  rowLines,
  shortcutLabel,
  sortRecords,
  unreadCount,
  workspaceTitle,
  workspaceTitlesFrom,
} from "./model.js";
import { t } from "./strings.js";

/** Keymap defaults (Appendix A); panel.init.keymap replaces them. */
export const DEFAULT_KEYMAP = Object.freeze({
  jumpToUnread: ["ctrl+shift+u"],
  clearAllNotifications: [],
});

/** Error codes that mean "native does not implement this method". */
const UNSUPPORTED_CODES = new Set(["method_not_found", "not_supported", "forbidden"]);
const RELOAD_DEBOUNCE_MS = 40;
const STATE_DEBOUNCE_MS = 400;
const STATUS_MS = 2500;
const PAGE_STEP = 10;
const TIME_REFRESH_MS = 60000;

/**
 * @param {{
 *   document: Document,
 *   bridge?: object,
 *   now?: () => number,
 *   installKeys?: Function,
 *   locale?: string,
 * }} options
 */
export function createApp(options) {
  const doc = options.document;
  const win = doc.defaultView;
  const bridge = options.bridge || defaultBridge;
  const now = options.now || (() => Date.now());
  const locale = options.locale;
  const $ = (id) => doc.getElementById(id);
  const els = {
    count: $("ntf-count"),
    jump: $("ntf-jump"),
    jumpLabel: $("ntf-jump-label"),
    jumpChip: $("ntf-jump-chip"),
    clear: $("ntf-clear"),
    status: $("ntf-status"),
    list: $("ntf-list"),
    empty: $("ntf-empty"),
    emptyTitle: $("ntf-empty-title"),
    emptyBody: $("ntf-empty-body"),
    emptySlash: $("ntf-empty-slash"),
    emptyBadge: $("ntf-empty-badge"),
    menu: $("ntf-menu"),
  };
  const state = {
    placement: "tab",
    grouped: true,
    records: [],
    markers: 0,
    titles: new Map(),
    focusedId: null,
    menuFor: null,
    loaded: false,
    destroyed: false,
    loadSeq: 0,
    reloadTimer: null,
    titlesTimer: null,
    stateTimer: null,
    statusTimer: null,
    timeTimer: null,
  };
  const cleanups = [];
  let keys = null;

  function listen(target, type, fn, opts) {
    target.addEventListener(type, fn, opts);
    cleanups.push(() => target.removeEventListener(type, fn, opts));
  }

  /* ---------------------------------------------------------------- status */

  function setStatus(text) {
    els.status.textContent = text || "";
    if (state.statusTimer) win.clearTimeout(state.statusTimer);
    state.statusTimer = text ? win.setTimeout(() => (els.status.textContent = ""), STATUS_MS) : null;
  }

  function errorMessage(err) {
    return (err && err.message) || String(err);
  }

  /* ------------------------------------------------------------- rendering */

  function find(id) {
    return state.records.find((r) => r.id === id) || null;
  }

  function rowFor(id) {
    for (const row of els.list.querySelectorAll(".ntf-row")) if (row.dataset.id === id) return row;
    return null;
  }

  function el(tag, className, text) {
    const node = doc.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function renderHeader() {
    const unread = unreadCount(state.records);
    els.count.hidden = unread === 0;
    els.count.textContent = unread > 99 ? "99+" : String(unread);
    els.count.setAttribute("aria-label", t("notifications.unreadBadge", { count: unread }));
    els.jump.disabled = unread === 0 && state.markers === 0;
    els.clear.disabled = state.records.length === 0;
    els.jumpLabel.textContent = t(state.placement === "popover" ? "notifications.jumpLatest" : "notifications.jumpLatestUnread");
    const chip = keys ? shortcutLabel(keys.bindingsFor("jumpToUnread")[0]) : "";
    els.jumpChip.textContent = chip;
    els.jumpChip.hidden = chip === "";
  }

  function renderEmpty(kind) {
    els.empty.hidden = kind === "list";
    els.list.hidden = kind !== "list";
    if (kind === "list") return;
    els.empty.dataset.state = kind;
    els.emptySlash.toggleAttribute("hidden", kind !== "empty");
    els.emptyBadge.toggleAttribute("hidden", kind !== "markers");
    if (kind === "markers") {
      const n = state.markers;
      els.emptyTitle.textContent = n === 1 ? t("notifications.markers.one") : t("notifications.markers.other", { count: n });
      els.emptyBody.textContent = "";
      els.emptyBody.hidden = true;
    } else {
      els.emptyTitle.textContent = t("notifications.empty.title");
      els.emptyBody.textContent = t(state.placement === "popover" ? "notifications.empty.bodyPopover" : "notifications.empty.bodyPane");
      els.emptyBody.hidden = false;
    }
  }

  function buildRow(record) {
    const row = el("div", "ntf-row");
    row.id = "ntf-row-" + state.records.indexOf(record);
    row.dataset.id = record.id;
    row.setAttribute("role", "option");
    row.tabIndex = -1;
    row.classList.toggle("ntf-unread", !record.read);
    row.setAttribute("aria-selected", "false");

    const indicator = el("span", "ntf-indicator");
    indicator.setAttribute("aria-hidden", "true");
    row.append(indicator);

    const main = el("div", "ntf-row-main");
    const lines = rowLines(record, state.titles);
    const pane = state.placement !== "popover";
    // Grouped lists and pane cards lead with the record title; the flat
    // popover list leads with the workspace title (cmux row layout).
    const primary = pane || state.grouped ? record.title.trim() || lines.primary : lines.primary;
    const secondary = pane || state.grouped ? "" : lines.secondary;
    const head = el("div", "ntf-row-head");
    head.append(el("span", "ntf-row-primary", primary));
    const time = el("time", "ntf-row-time", formatShortTime(record.created_at_ms, now(), locale));
    if (record.created_at_ms > 0) {
      time.dateTime = new Date(record.created_at_ms).toISOString();
      time.title = formatFullTime(record.created_at_ms, locale);
    }
    head.append(time);
    main.append(head);
    if (secondary && secondary !== primary) main.append(el("div", "ntf-row-secondary", secondary));
    if (lines.detail && lines.detail !== primary) main.append(el("div", "ntf-row-body", lines.detail));
    const caption = captionFor(record);
    if (caption) main.append(el("div", "ntf-row-caption", caption));
    row.append(main);

    const clear = el("button", "ntf-row-clear");
    clear.type = "button";
    clear.tabIndex = -1;
    clear.dataset.action = "dismiss";
    clear.title = t("notifications.row.clear");
    clear.setAttribute("aria-label", t("notifications.row.clear"));
    clear.textContent = "✕";
    row.append(clear);

    const label = [record.read ? "" : t("notifications.row.unread"), primary, secondary, lines.detail, caption, time.textContent];
    row.setAttribute("aria-label", label.filter((s) => s).join(", "));
    return row;
  }

  /** Caption line: workspace title (pane, flat) and the surface title. */
  function captionFor(record) {
    const parts = [];
    if (!state.grouped && state.placement !== "popover") {
      const ws = workspaceTitle(record, state.titles);
      if (ws) parts.push(ws);
    }
    if (state.grouped) {
      if (record.surface_title) parts.push(record.surface_title);
      else if (!record.surface) parts.push(t("notifications.row.workspaceLevel"));
    }
    return parts.join(" · ");
  }

  function renderList() {
    const restoreFocus = els.list.contains(doc.activeElement);
    const nodes = [];
    if (state.grouped) {
      groupRecords(state.records, state.titles).forEach((group, gi) => {
        const section = el("div", "ntf-group");
        section.setAttribute("role", "group");
        const title = group.title || t("notifications.group.unknown");
        const heading = el("div", "ntf-group-title");
        heading.id = "ntf-group-" + gi;
        heading.append(el("span", "ntf-group-name", title));
        if (group.unread > 0) heading.append(el("span", "ntf-group-count", String(group.unread)));
        section.setAttribute("aria-labelledby", heading.id);
        section.append(heading);
        for (const r of group.records) section.append(buildRow(r));
        nodes.push(section);
      });
    } else {
      for (const r of state.records) nodes.push(buildRow(r));
    }
    els.list.replaceChildren(...nodes);
    if (state.focusedId && !find(state.focusedId)) state.focusedId = null;
    if (!state.focusedId && state.records.length > 0) state.focusedId = orderedIds()[0];
    applyFocus(restoreFocus);
  }

  /** Record ids in visual order (groups reorder the flat list). */
  function orderedIds() {
    return Array.from(els.list.querySelectorAll(".ntf-row"), (row) => row.dataset.id);
  }

  /** Roving tabindex: the focused row is the list's tab stop. */
  function applyFocus(moveDomFocus) {
    let target = null;
    for (const row of els.list.querySelectorAll(".ntf-row")) {
      const on = row.dataset.id === state.focusedId;
      row.tabIndex = on ? 0 : -1;
      row.setAttribute("aria-selected", on ? "true" : "false");
      if (on) target = row;
    }
    if (moveDomFocus && target) {
      target.focus({ preventScroll: true });
      if (typeof target.scrollIntoView === "function") target.scrollIntoView({ block: "nearest" });
    }
  }

  function render() {
    renderHeader();
    const kind = bodyState(state.records, state.markers);
    renderEmpty(kind);
    if (kind === "list") renderList();
    else els.list.replaceChildren();
    if (state.menuFor && !find(state.menuFor)) closeMenu(false);
  }

  /* ----------------------------------------------------------------- data */

  function applySnapshot(result) {
    state.records = recordsFrom(result);
    state.markers = markerCountFrom(result);
    if (result && typeof result === "object" && !Array.isArray(result) && Array.isArray(result.workspaces)) {
      state.titles = workspaceTitlesFrom(result.workspaces);
    }
    state.loaded = true;
    render();
  }

  /** Fetches the records (`notification.list`); only the newest load applies. */
  async function reload() {
    const seq = ++state.loadSeq;
    try {
      const result = await bridge.call("notification.list", {});
      if (seq !== state.loadSeq || state.destroyed) return;
      applySnapshot(result);
    } catch (err) {
      if (seq !== state.loadSeq || state.destroyed) return;
      setStatus(t("notifications.status.loadFailed", { message: errorMessage(err) }));
      if (!state.loaded) render();
    }
  }

  async function reloadTitles() {
    try {
      const result = await bridge.call("workspace.list", {});
      if (state.destroyed) return;
      state.titles = workspaceTitlesFrom(result);
      render();
    } catch (err) {
      // Titles fall back to the ones carried by the records.
      if (!err || !UNSUPPORTED_CODES.has(err.code)) console.warn("[notifications] workspace.list failed", err);
    }
  }

  function scheduleReload() {
    if (state.reloadTimer) win.clearTimeout(state.reloadTimer);
    state.reloadTimer = win.setTimeout(() => {
      state.reloadTimer = null;
      reload();
    }, RELOAD_DEBOUNCE_MS);
  }

  function scheduleTitles() {
    if (state.titlesTimer) win.clearTimeout(state.titlesTimer);
    state.titlesTimer = win.setTimeout(() => {
      state.titlesTimer = null;
      reloadTitles();
    }, RELOAD_DEBOUNCE_MS);
  }

  function onFrame(frame) {
    const name = frameName(frame);
    if (isRecordEvent(name)) scheduleReload();
    else if (isWorkspaceEvent(name)) scheduleTitles();
  }

  function saveState() {
    if (state.stateTimer) win.clearTimeout(state.stateTimer);
    state.stateTimer = win.setTimeout(() => {
      state.stateTimer = null;
      if (!bridge.available) return;
      bridge.panel.setState({ v: 1, focused_id: state.focusedId || null }).catch(() => {});
    }, STATE_DEBOUNCE_MS);
  }

  /* -------------------------------------------------------------- actions */

  /**
   * Runs a bridge call after an optimistic local change; a failure shows the
   * error and reloads the authoritative list.
   */
  async function act(method, params, optimistic) {
    if (optimistic) {
      optimistic();
      render();
    }
    try {
      await bridge.call(method, params);
      return true;
    } catch (err) {
      setStatus(t("notifications.status.actionFailed", { message: errorMessage(err) }));
      scheduleReload();
      return false;
    }
  }

  function closePopover() {
    if (state.placement !== "popover") return;
    bridge.call("panel.notifications.close_popover", {}).catch(() => {});
  }

  async function open(id) {
    const record = find(id);
    if (!record) return;
    const ok = await act("notification.open", { notification_id: id }, () => (record.read = true));
    if (ok) closePopover();
  }

  function setRead(id, read) {
    const record = find(id);
    if (!record || record.read === read) return Promise.resolve(false);
    const method = read ? "notification.mark_read" : "panel.notifications.mark_unread";
    return act(method, { notification_id: id }, () => (record.read = read));
  }

  function toggleRead(id) {
    const record = find(id);
    return record ? setRead(id, !record.read) : Promise.resolve(false);
  }

  function dismiss(id) {
    if (!find(id)) return Promise.resolve(false);
    const hadFocus = els.list.contains(doc.activeElement);
    if (state.focusedId === id) {
      const ids = orderedIds();
      const i = ids.indexOf(id);
      state.focusedId = ids[i + 1] || ids[i - 1] || null;
    }
    const done = act("notification.dismiss", { notification_id: id }, () => {
      state.records = state.records.filter((r) => r.id !== id);
    });
    if (hadFocus) applyFocus(true);
    return done;
  }

  function clearAll() {
    if (state.records.length === 0) return Promise.resolve(false);
    return act("notification.clear", {}, () => {
      state.records = [];
      state.focusedId = null;
    });
  }

  async function jumpToUnread() {
    if (unreadCount(state.records) === 0 && state.markers === 0) {
      setStatus(t("notifications.status.nothingUnread"));
      return false;
    }
    const ok = await act("notification.jump_to_unread", {});
    if (ok) closePopover();
    return ok;
  }

  async function copy(id) {
    const record = find(id);
    if (!record) return false;
    try {
      await bridge.panel.clipboardWrite(copyText(record, state.titles));
      setStatus(t("notifications.status.copied"));
      return true;
    } catch (err) {
      setStatus(t("notifications.status.actionFailed", { message: errorMessage(err) }));
      return false;
    }
  }

  function runRowAction(action, id) {
    switch (action) {
      case "open":
        return open(id);
      case "copy":
        return copy(id);
      case "toggleRead":
        return toggleRead(id);
      case "dismiss":
        return dismiss(id);
      default:
        return undefined;
    }
  }

  /* ------------------------------------------------------- focus and keys */

  function focusRow(id, moveDomFocus = true) {
    if (!id || !find(id)) return;
    state.focusedId = id;
    applyFocus(moveDomFocus);
    saveState();
  }

  function moveFocus(delta, absolute) {
    const ids = orderedIds();
    if (ids.length === 0) return;
    let i = ids.indexOf(state.focusedId);
    if (absolute === "first") i = 0;
    else if (absolute === "last") i = ids.length - 1;
    else i = i < 0 ? 0 : Math.min(ids.length - 1, Math.max(0, i + delta));
    focusRow(ids[i]);
  }

  /** Focus the list (pane shown or focused): the focused row, else the first. */
  function focusList() {
    if (state.records.length === 0) return;
    if (!state.focusedId || !find(state.focusedId)) state.focusedId = orderedIds()[0] || null;
    applyFocus(true);
  }

  function rowOf(target) {
    return target && typeof target.closest === "function" ? target.closest(".ntf-row") : null;
  }

  function onListKeydown(e) {
    if (e.defaultPrevented || e.isComposing) return;
    const row = rowOf(e.target);
    const id = row ? row.dataset.id : state.focusedId;
    const plain = !e.ctrlKey && !e.altKey && !e.metaKey;
    let handled = true;
    if (plain && (e.key === "ArrowDown" || (e.key === "j" && !e.shiftKey))) moveFocus(1);
    else if (plain && (e.key === "ArrowUp" || (e.key === "k" && !e.shiftKey))) moveFocus(-1);
    else if (plain && e.key === "Home") moveFocus(0, "first");
    else if (plain && e.key === "End") moveFocus(0, "last");
    else if (plain && e.key === "PageDown") moveFocus(PAGE_STEP);
    else if (plain && e.key === "PageUp") moveFocus(-PAGE_STEP);
    else if (plain && e.key === "Enter" && id) open(id);
    else if (plain && e.key === " " && id) toggleRead(id);
    else if (plain && (e.key === "Delete" || e.key === "Backspace") && id) dismiss(id);
    else if ((e.key === "ContextMenu" || (e.key === "F10" && e.shiftKey)) && id) openMenu(id, null);
    else if (e.ctrlKey && !e.altKey && !e.shiftKey && (e.key === "c" || e.key === "C") && id) copy(id);
    else handled = false;
    if (handled) {
      e.preventDefault();
      e.stopPropagation();
    }
  }

  function onListClick(e) {
    const row = rowOf(e.target);
    if (!row) return;
    const id = row.dataset.id;
    const button = e.target.closest("button[data-action]");
    if (button && row.contains(button)) {
      e.stopPropagation();
      runRowAction(button.dataset.action, id);
      return;
    }
    focusRow(id);
    open(id);
  }

  function onListContextMenu(e) {
    const row = rowOf(e.target);
    if (!row) return;
    e.preventDefault();
    focusRow(row.dataset.id);
    openMenu(row.dataset.id, { x: e.clientX, y: e.clientY });
  }

  function onDocKeydown(e) {
    if (e.defaultPrevented) return;
    if (e.key === "Escape" && !e.ctrlKey && !e.altKey) {
      if (state.menuFor) return; // the menu handles its own Escape
      if (state.placement === "popover") {
        e.preventDefault();
        closePopover();
      }
    }
  }

  /* ------------------------------------------------------------------ menu */

  function menuItems() {
    return Array.from(els.menu.querySelectorAll("[role=menuitem]"));
  }

  function openMenu(id, point) {
    const record = find(id);
    if (!record) return;
    state.menuFor = id;
    const toggle = els.menu.querySelector('[data-action="toggleRead"]');
    toggle.textContent = t(record.read ? "notifications.menu.markUnread" : "notifications.menu.markRead");
    els.menu.hidden = false;
    let x = point ? point.x : 0;
    let y = point ? point.y : 0;
    if (!point) {
      const row = rowFor(id);
      const rect = row ? row.getBoundingClientRect() : { left: 0, bottom: 0 };
      x = rect.left + 16;
      y = rect.bottom;
    }
    const w = els.menu.offsetWidth || 0;
    const h = els.menu.offsetHeight || 0;
    const vw = win.innerWidth || 0;
    const vh = win.innerHeight || 0;
    if (vw && x + w > vw) x = Math.max(0, vw - w - 4);
    if (vh && y + h > vh) y = Math.max(0, y - h);
    els.menu.style.setProperty("left", Math.round(x) + "px");
    els.menu.style.setProperty("top", Math.round(y) + "px");
    menuItems()[0].focus();
  }

  function closeMenu(returnFocus = true) {
    if (!state.menuFor) return;
    const id = state.menuFor;
    state.menuFor = null;
    els.menu.hidden = true;
    if (returnFocus && find(id)) focusRow(id);
  }

  function onMenuKeydown(e) {
    const items = menuItems();
    const i = items.indexOf(doc.activeElement);
    let handled = true;
    if (e.key === "ArrowDown") items[(i + 1) % items.length].focus();
    else if (e.key === "ArrowUp") items[(i - 1 + items.length) % items.length].focus();
    else if (e.key === "Home") items[0].focus();
    else if (e.key === "End") items[items.length - 1].focus();
    else if (e.key === "Escape" || e.key === "Tab") closeMenu(true);
    else handled = false;
    if (handled) {
      e.preventDefault();
      e.stopPropagation();
    }
  }

  function onMenuClick(e) {
    const item = e.target.closest("[role=menuitem]");
    if (!item || !state.menuFor) return;
    const id = state.menuFor;
    const action = item.dataset.action;
    closeMenu(action !== "dismiss" && action !== "open");
    const done = runRowAction(action, id);
    // Dismiss picked the next row: give it the focus the menu had.
    if (action === "dismiss") applyFocus(true);
    return done;
  }

  function onDocPointerDown(e) {
    if (state.menuFor && !els.menu.contains(e.target)) closeMenu(false);
  }

  /* ------------------------------------------------------------ lifecycle */

  function readPlacement(ctx) {
    const params = (ctx && ctx.params) || {};
    const placement = params.placement === "popover" || params.popover === true ? "popover" : "tab";
    state.placement = placement;
    // cmux's popover is a flat list; wmux groups by workspace unless the
    // host asks for the flat list (`group_by: "none"`).
    state.grouped = params.group_by !== "none";
    doc.documentElement.dataset.placement = placement;
    doc.documentElement.dataset.grouped = state.grouped ? "true" : "false";
    const saved = ctx && ctx.state;
    if (saved && typeof saved === "object" && typeof saved.focused_id === "string") state.focusedId = saved.focused_id;
    if (params.payload && typeof params.payload === "object") applySnapshot(params.payload);
  }

  function installKeyHandlers() {
    keys = (options.installKeys || installKeys)();
    keys.setKeymap(DEFAULT_KEYMAP);
    if (bridge.context && bridge.context.keymap !== undefined) keys.setKeymap(bridge.context.keymap);
    cleanups.push(keys.handle("jumpToUnread", () => jumpToUnread()));
    cleanups.push(keys.handle("clearAllNotifications", () => clearAll()));
  }

  function runCommand(payload) {
    const action = payload && typeof payload.action === "string" ? payload.action : "";
    switch (action) {
      case "jumpToUnread":
        return jumpToUnread();
      case "clearAllNotifications":
        return clearAll();
      case "focus":
        return focusList();
      case "refresh":
        return reload();
      default:
        return undefined;
    }
  }

  async function start() {
    applyStrings(doc);
    installKeyHandlers();
    listen(els.list, "keydown", onListKeydown);
    listen(els.list, "click", onListClick);
    listen(els.list, "contextmenu", onListContextMenu);
    listen(els.list, "focusin", (e) => {
      const row = rowOf(e.target);
      if (row && row.dataset.id !== state.focusedId) focusRow(row.dataset.id, false);
    });
    listen(els.menu, "keydown", onMenuKeydown);
    listen(els.menu, "click", onMenuClick);
    listen(doc, "keydown", onDocKeydown);
    listen(doc, "pointerdown", onDocPointerDown);
    listen(doc, "mousedown", onDocPointerDown);
    listen(els.jump, "click", () => jumpToUnread());
    listen(els.clear, "click", () => clearAll());
    // Pane shown or focused: the first (or last focused) row takes focus.
    listen(win, "focus", () => {
      if (!els.list.contains(doc.activeElement) && !state.menuFor) focusList();
    });
    cleanups.push(bridge.on("cmux.event", onFrame));
    cleanups.push(bridge.on("panel.notifications.snapshot", (p) => applySnapshot(p)));
    cleanups.push(bridge.on("panel.notifications.command", runCommand));
    cleanups.push(bridge.on("keymap", (km) => keys && (keys.setKeymap(km), renderHeader())));
    state.timeTimer = win.setInterval(() => state.records.length && render(), TIME_REFRESH_MS);
    render();

    if (!bridge.available) {
      setStatus(t("notifications.status.offline"));
      return api;
    }
    let ctx = null;
    try {
      ctx = await bridge.ready();
    } catch (err) {
      setStatus(t("notifications.status.loadFailed", { message: errorMessage(err) }));
      return api;
    }
    if (state.destroyed) return api;
    // The latest panel.init wins (ready() keeps resolving with the first).
    ctx = bridge.context || ctx;
    readPlacement(ctx);
    cleanups.push(
      bridge.on("panel.init", (next) => {
        readPlacement(next);
        render();
      }),
    );
    if (ctx && ctx.keymap !== undefined) keys.setKeymap(ctx.keymap);
    bridge.panel.setTitle(t("notifications.title")).catch(() => {});
    bridge.panel.subscribe(["notification", "workspace", "wmux"]).catch(() => {});
    await Promise.all([reload(), reloadTitles()]);
    if (!state.destroyed && doc.hasFocus && doc.hasFocus()) focusList();
    return api;
  }

  function destroy() {
    state.destroyed = true;
    for (const timer of [state.reloadTimer, state.titlesTimer, state.stateTimer, state.statusTimer]) {
      if (timer) win.clearTimeout(timer);
    }
    if (state.timeTimer) win.clearInterval(state.timeTimer);
    while (cleanups.length) {
      try {
        cleanups.pop()();
      } catch {
        // keep tearing down
      }
    }
  }

  const api = {
    start,
    destroy,
    reload,
    render,
    open,
    setRead,
    toggleRead,
    dismiss,
    clearAll,
    jumpToUnread,
    copy,
    focusRow,
    focusList,
    openMenu,
    closeMenu,
    runCommand,
    applySnapshot,
    get state() {
      return state;
    },
  };
  return api;
}
