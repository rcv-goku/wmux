/**
 * Task Manager application: PanelKind "task_manager" (ARCHITECTURE ADR-6.11,
 * placement: top-level PanelHostWindow), entry
 * https://task-manager.wmux.example/task-manager/index.html. Summary cards,
 * Coding Agents, Program Totals, Child Process RSS and the window > workspace
 * > pane > surface > process / webview hierarchy with Name / CPU / Memory /
 * Proc columns, sorting, a 3 s refresh while visible, jump to owner and a
 * confirmed graceful kill. The native contract is documented in README.md.
 *
 *   const app = createApp({ document });
 *   await app.start();
 *
 * The document, bridge, clock and refresh interval are injectable so the
 * jsdom tests in test/web-node/task-manager/ drive the real code.
 */
import { wmux as defaultBridge } from "../_shared/wmux-bridge.js";
import { applyStrings } from "../_shared/strings.js";
import {
  codingAgents,
  defaultDirection,
  flatten,
  formatBytes,
  formatCpu,
  formatTime,
  hasUsage,
  killPids,
  normalizeMemory,
  normalizeTop,
  programTotals,
  sortRows,
  sortTree,
} from "./model.js";
import { t } from "./strings.js";

/** cmux refreshes every 3 seconds while the window is visible. */
export const REFRESH_MS = 3000;
const UNSUPPORTED_CODES = new Set(["method_not_found", "not_supported"]);
const MAX_COLLAPSED_STATE = 200;
const COLUMNS = Object.freeze([
  { sort: "name", label: "tm.col.name" },
  { sort: "cpu", label: "tm.col.cpu" },
  { sort: "mem", label: "tm.col.memory" },
  { sort: "proc", label: "tm.col.proc" },
]);

function errorMessage(err) {
  return err && typeof err.message === "string" ? err.message : String(err);
}

function errorCode(err) {
  return err && typeof err.code === "string" ? err.code : "";
}

function baseName(name) {
  return String(name || "")
    .split(/[\\/]/)
    .pop();
}

/**
 * @param {{
 *   document: Document,
 *   bridge?: typeof defaultBridge,
 *   refreshMs?: number,
 *   now?: () => Date,
 *   readyTimeoutMs?: number,
 * }} options
 */
export function createApp(options) {
  const doc = options.document;
  const bridge = options.bridge || defaultBridge;
  const refreshMs = options.refreshMs || REFRESH_MS;
  const now = options.now || (() => new Date());
  const $ = (id) => doc.getElementById(id);
  const ui = {
    refreshing: $("tm-refreshing"),
    processes: $("tm-processes"),
    refresh: $("tm-refresh"),
    banner: $("tm-banner"),
    cards: {
      cpu: $("tm-card-cpu"),
      memory: $("tm-card-memory"),
      app: $("tm-card-app"),
      child: $("tm-card-child"),
      processes: $("tm-card-processes"),
      updated: $("tm-card-updated"),
    },
    state: $("tm-state"),
    stateTitle: $("tm-state-title"),
    stateBody: $("tm-state-body"),
    main: $("tm-main"),
    tables: { agents: $("tm-agents"), programs: $("tm-programs"), child: $("tm-child"), tree: $("tm-tree") },
    none: { agents: $("tm-agents-none"), programs: $("tm-programs-none"), child: $("tm-child-none") },
    menu: $("tm-menu"),
    confirm: $("tm-confirm"),
    confirmText: $("tm-confirm-text"),
    confirmOk: $("tm-confirm-ok"),
    confirmCancel: $("tm-confirm-cancel"),
  };

  const state = {
    started: false,
    destroyed: false,
    top: null,
    memory: null,
    updated: null,
    loadError: null,
    refreshFailed: false,
    busy: false,
    inFlight: null,
    timer: null,
    sort: { key: null, dir: "desc" },
    showProcesses: false,
    collapsed: new Set(),
    selected: null,
    menuRow: null,
    confirmResolve: null,
    killError: "",
  };
  /** Rendered rows by `<section>|<key>`. */
  const rows = new Map();
  const cleanups = [];

  function listen(target, type, fn, opts) {
    target.addEventListener(type, fn, opts);
    cleanups.push(() => target.removeEventListener(type, fn, opts));
  }

  function isVisible() {
    return doc.visibilityState !== "hidden";
  }

  function saveState() {
    if (!bridge.available) return;
    const collapsed = Array.from(state.collapsed).slice(-MAX_COLLAPSED_STATE);
    bridge.panel
      .setState({ v: 1, show_processes: state.showProcesses, sort: { ...state.sort }, collapsed })
      .catch(() => {});
  }

  function restoreState(saved) {
    if (!saved || typeof saved !== "object") return;
    if (typeof saved.show_processes === "boolean") state.showProcesses = saved.show_processes;
    const s = saved.sort;
    if (s && typeof s === "object" && ["name", "cpu", "mem", "proc"].includes(s.key)) {
      state.sort = { key: s.key, dir: s.dir === "asc" ? "asc" : "desc" };
    }
    if (Array.isArray(saved.collapsed)) {
      state.collapsed = new Set(
        saved.collapsed.filter((k) => typeof k === "string").slice(-MAX_COLLAPSED_STATE),
      );
    }
  }

  /* ---------------------------------------------------------------------- */
  /* labels                                                                 */
  /* ---------------------------------------------------------------------- */

  function flagList(node, names) {
    const out = [];
    for (const [flag, key] of names) if (node.flags && node.flags[flag]) out.push(t(key));
    return out;
  }

  /** `{name, detail}` for any row (tree node or section row). */
  function rowLabel(row) {
    switch (row.kind) {
      case "window":
        return {
          name: row.title || `${t("tm.kind.window")} ${row.ref}`.trim(),
          detail: flagList(row, [["hidden", "tm.flag.hidden"]]),
        };
      case "workspace":
        return {
          name: row.title || row.ref,
          detail: flagList(row, [
            ["selected", "tm.flag.selected"],
            ["pinned", "tm.flag.pinned"],
          ]),
        };
      case "tag": {
        const detail = flagList(row, [["pidOnly", "tm.flag.pidOnly"]]);
        if (row.pid !== null) detail.push(t("tm.pid", { pid: row.pid }));
        return { name: `${row.tagKey} "${row.tagValue}"`, detail };
      }
      case "pane":
        return {
          name: `${t("tm.kind.pane")} ${row.ref}`.trim(),
          detail: flagList(row, [["focused", "tm.flag.focused"]]),
        };
      case "surface": {
        const detail = [];
        if (row.type === "terminal" || row.type === "browser") detail.push(t(`tm.kind.${row.type}`));
        detail.push(...flagList(row, [["selected", "tm.flag.selected"]]));
        if (row.tty) detail.push(row.tty);
        return { name: row.title || row.ref, detail };
      }
      case "webview":
        return {
          name: row.title || t("tm.kind.webview"),
          detail: row.pid !== null ? [t("tm.pid", { pid: row.pid })] : [],
        };
      case "process": {
        const detail = row.pid !== null ? [t("tm.pid", { pid: row.pid })] : [];
        if (row.agent) detail.push(row.agent);
        if (row.attribution) detail.push(row.attribution);
        return { name: baseName(row.name) || t("tm.pid", { pid: row.pid }), detail };
      }
      case "agent":
        return { name: row.title, detail: [row.detail, t("tm.pid", { pid: row.pid })].filter(Boolean) };
      default:
        return { name: row.title, detail: row.detail ? [row.detail] : [] };
    }
  }

  /** Name used in the kill confirmation for a single PID. */
  function killName(row) {
    if (row.kind === "process") return baseName(row.name) || String(row.pid);
    if (row.kind === "agent") return row.title;
    if (row.kind === "program") return row.title;
    if (row.kind === "tag") return row.tagKey;
    // A surface / pane / workspace with one top-level process: name that process.
    let found = null;
    const visit = (n) => {
      for (const c of n.children || []) {
        if (found) return;
        if (c.kind === "process") found = c;
        else if (c.kind !== "webview") visit(c);
      }
    };
    visit(row);
    return found ? baseName(found.name) : rowLabel(row).name;
  }

  /* ---------------------------------------------------------------------- */
  /* rendering                                                              */
  /* ---------------------------------------------------------------------- */

  function renderHead(table) {
    const tr = doc.createElement("tr");
    for (const col of COLUMNS) {
      const th = doc.createElement("th");
      th.scope = "col";
      th.className = `tm-col-${col.sort}`;
      const active = state.sort.key === col.sort;
      th.setAttribute("aria-sort", active ? (state.sort.dir === "asc" ? "ascending" : "descending") : "none");
      const btn = doc.createElement("button");
      btn.type = "button";
      btn.className = "tm-sort";
      btn.dataset.sort = col.sort;
      btn.textContent = t(col.label);
      btn.title = t("tm.sort", { column: t(col.label) });
      if (active) btn.dataset.dir = state.sort.dir;
      th.append(btn);
      tr.append(th);
    }
    table.tHead.replaceChildren(tr);
  }

  function cell(text, cls) {
    const td = doc.createElement("td");
    td.className = cls;
    td.textContent = text;
    return td;
  }

  function renderRow(section, row, extra) {
    const key = `${section}|${row.key}`;
    rows.set(key, row);
    const tr = doc.createElement("tr");
    tr.dataset.key = key;
    tr.dataset.kind = row.kind;
    tr.tabIndex = state.selected === key ? 0 : -1;
    tr.classList.toggle("is-selected", state.selected === key);
    tr.setAttribute("aria-selected", state.selected === key ? "true" : "false");
    const label = rowLabel(row);
    const name = doc.createElement("td");
    name.className = "tm-col-name";
    if (extra) {
      tr.setAttribute("role", "row");
      tr.setAttribute("aria-level", String(extra.depth + 1));
      name.style.setProperty("--tm-depth", String(extra.depth));
      if (extra.expandable) {
        tr.setAttribute("aria-expanded", extra.expanded ? "true" : "false");
        const toggle = doc.createElement("button");
        toggle.type = "button";
        toggle.className = "tm-toggle-row";
        toggle.tabIndex = -1;
        toggle.setAttribute("aria-label", extra.expanded ? t("tm.collapse") : t("tm.expand"));
        name.append(toggle);
      } else {
        const pad = doc.createElement("span");
        pad.className = "tm-toggle-pad";
        name.append(pad);
      }
    }
    const nameText = doc.createElement("span");
    nameText.className = "tm-name";
    nameText.textContent = label.name;
    name.append(nameText);
    if (label.detail.length) {
      const detail = doc.createElement("span");
      detail.className = "tm-detail";
      detail.textContent = label.detail.join(" · ");
      name.append(detail);
    }
    tr.append(
      name,
      cell(formatCpu(row.cpu), "tm-col-cpu"),
      cell(formatBytes(row.mem), "tm-col-mem"),
      cell(String(row.proc || 0), "tm-col-proc"),
    );
    return tr;
  }

  function renderTable(section, list) {
    const table = ui.tables[section];
    renderHead(table);
    const body = table.tBodies[0];
    body.replaceChildren(...list.map((row) => renderRow(section, row)));
    if (ui.none[section]) ui.none[section].hidden = list.length > 0;
    table.hidden = list.length === 0;
  }

  function renderTree() {
    const table = ui.tables.tree;
    renderHead(table);
    const tree = sortTree(state.top.windows, state.sort.key, state.sort.dir);
    const visible = flatten(tree, state.collapsed, state.showProcesses);
    table.tBodies[0].replaceChildren(...visible.map((r) => renderRow("tree", r.node, r)));
  }

  function renderCards() {
    const none = t("tm.card.none");
    const top = state.top;
    const mem = state.memory;
    ui.cards.cpu.textContent = top ? formatCpu(top.totals.cpu) : none;
    ui.cards.memory.textContent = top ? formatBytes(top.totals.mem) : none;
    ui.cards.app.textContent = mem && mem.app !== null ? formatBytes(mem.app) : none;
    ui.cards.child.textContent = mem && mem.child !== null ? formatBytes(mem.child) : none;
    ui.cards.processes.textContent = top ? String(top.totals.proc) : none;
    ui.cards.updated.textContent = state.updated ? formatTime(state.updated) : none;
  }

  function setStateText(titleKey, body) {
    ui.stateTitle.textContent = t(titleKey);
    ui.stateBody.textContent = body || "";
    ui.stateBody.hidden = !body;
  }

  function render() {
    const active = doc.activeElement;
    const focusedKey = active && ui.main.contains(active) ? rowKeyOf(active) : null;
    // Header sort buttons are rebuilt too (every refresh): remember the focused one.
    const focusedSort = !focusedKey && active && ui.main.contains(active) ? sortFocusOf(active) : null;
    rows.clear();
    renderCards();
    ui.refreshing.hidden = !state.busy;
    ui.processes.checked = state.showProcesses;
    const banner = state.killError || (state.refreshFailed ? t("tm.state.refreshFailed") : "");
    ui.banner.textContent = banner;
    ui.banner.hidden = !banner;

    let showMain = false;
    if (!bridge.available) {
      setStateText("tm.state.offline");
    } else if (!state.top) {
      if (state.loadError) {
        const unsupported = UNSUPPORTED_CODES.has(errorCode(state.loadError));
        setStateText(
          "tm.state.loadFailed",
          unsupported ? t("tm.state.unsupported") : errorMessage(state.loadError),
        );
      } else {
        setStateText("tm.state.loading");
      }
    } else if (!hasUsage(state.top)) {
      setStateText("tm.state.empty", t("tm.state.emptyBody"));
    } else {
      showMain = true;
    }
    ui.state.hidden = showMain;
    ui.main.hidden = !showMain;
    if (!showMain) return;

    const sortKey = state.sort.key;
    const dir = state.sort.dir;
    // Sections without an explicit sort show the heaviest first.
    renderTable("agents", sortRows(codingAgents(state.top), sortKey || "cpu", sortKey ? dir : "desc"));
    renderTable("programs", sortRows(programTotals(state.top), sortKey || "cpu", sortKey ? dir : "desc"));
    renderTable(
      "child",
      sortRows(state.memory ? state.memory.groups : [], sortKey || "mem", sortKey ? dir : "desc"),
    );
    renderTree();
    if (state.selected && !rows.has(state.selected)) state.selected = null;
    // Refreshes rebuild the rows and headers; keep keyboard focus on the same one.
    const el = focusedKey ? rowElement(focusedKey) : focusedSort ? sortButton(focusedSort) : null;
    if (el) el.focus();
  }

  /* ---------------------------------------------------------------------- */
  /* refresh                                                                */
  /* ---------------------------------------------------------------------- */

  function cancelTimer() {
    if (state.timer !== null) clearTimeout(state.timer);
    state.timer = null;
  }

  function schedule() {
    cancelTimer();
    if (state.destroyed || !isVisible() || !bridge.available) return;
    state.timer = setTimeout(() => {
      state.timer = null;
      refresh();
    }, refreshMs);
  }

  async function load() {
    const [topResult, memResult] = await Promise.all([
      bridge.call("system.top", { all_windows: true, include_processes: true }),
      bridge.call("system.memory", { all_windows: true }).catch(() => null),
    ]);
    const top = normalizeTop(topResult);
    if (!top) {
      const err = new Error("malformed system.top reply");
      err.code = "internal_error";
      throw err;
    }
    return { top, memory: normalizeMemory(memResult) };
  }

  /** Refresh now; concurrent calls share the request in flight. */
  function refresh() {
    if (state.destroyed || !bridge.available) return Promise.resolve();
    if (state.inFlight) return state.inFlight;
    cancelTimer();
    state.busy = true;
    ui.refreshing.hidden = false;
    state.inFlight = load()
      .then(
        ({ top, memory }) => {
          if (state.destroyed) return;
          state.top = top;
          state.memory = memory;
          state.updated = now();
          state.loadError = null;
          state.refreshFailed = false;
        },
        (err) => {
          if (state.destroyed) return;
          if (!state.top) state.loadError = err;
          else if (errorCode(err) !== "rate_limited") state.refreshFailed = true;
          console.warn("[task-manager] refresh failed:", errorMessage(err));
        },
      )
      .finally(() => {
        state.inFlight = null;
        state.busy = false;
        if (state.destroyed) return;
        render();
        schedule();
      });
    return state.inFlight;
  }

  function onVisibility() {
    if (isVisible()) refresh();
    else cancelTimer();
  }

  /* ---------------------------------------------------------------------- */
  /* actions                                                                */
  /* ---------------------------------------------------------------------- */

  function jump(method, params) {
    return bridge.call(method, params).catch((err) => {
      state.killError = "";
      ui.banner.textContent = t("tm.jump.failed", { message: errorMessage(err) });
      ui.banner.hidden = false;
    });
  }

  function withWindow(owner, params) {
    return owner.window_id ? { ...params, window_id: owner.window_id } : params;
  }

  function viewWorkspace(row) {
    const o = row.owner || {};
    if (!o.workspace_id) return Promise.resolve();
    return jump("workspace.select", withWindow(o, { workspace_id: o.workspace_id }));
  }

  function viewTerminal(row) {
    const o = row.owner || {};
    if (!o.surface_id) return viewWorkspace(row);
    const params = withWindow(o, { surface_id: o.surface_id });
    if (o.workspace_id) params.workspace_id = o.workspace_id;
    return jump("surface.focus", params);
  }

  /** Activate / double-click: jump to the row's owner. */
  function activate(row) {
    if (!row) return Promise.resolve();
    const o = row.owner || {};
    if (row.kind === "window" && o.window_id) return jump("window.focus", { window_id: o.window_id });
    if (row.kind === "workspace") return viewWorkspace(row);
    if (row.kind === "pane" && o.pane_id) {
      const params = withWindow(o, { pane_id: o.pane_id });
      if (o.workspace_id) params.workspace_id = o.workspace_id;
      return jump("pane.focus", params);
    }
    if (o.surface_id) return viewTerminal(row);
    if (o.workspace_id) return viewWorkspace(row);
    return Promise.resolve();
  }

  function confirmKill(text) {
    if (state.confirmResolve) state.confirmResolve(false);
    ui.confirmText.textContent = text;
    ui.confirm.hidden = false;
    ui.confirmCancel.focus();
    return new Promise((resolve) => {
      state.confirmResolve = (ok) => {
        state.confirmResolve = null;
        ui.confirm.hidden = true;
        resolve(ok);
      };
    });
  }

  /** "Kill Process...": confirm, ask native for a graceful kill, refresh. */
  async function kill(row) {
    const pids = killPids(row);
    if (!pids.length) return false;
    const text =
      pids.length === 1
        ? t("tm.kill.one", { name: killName(row), pid: pids[0] })
        : t("tm.kill.many", { count: pids.length, pids: pids.join(", ") });
    const ok = await confirmKill(text);
    if (!ok || state.destroyed) return false;
    state.killError = "";
    try {
      const result = await bridge.call("panel.task_manager.kill", { pids });
      const failed = result && Array.isArray(result.failed) ? result.failed : [];
      if (failed.length) {
        const first = failed[0] || {};
        state.killError = t("tm.kill.failed", { message: String(first.message || first.error || first.pid) });
      }
    } catch (err) {
      state.killError = t("tm.kill.failed", { message: errorMessage(err) });
    }
    if (state.destroyed) return false;
    render();
    await refresh();
    return !state.killError;
  }

  /* ---------------------------------------------------------------------- */
  /* selection, menu, sorting                                               */
  /* ---------------------------------------------------------------------- */

  function rowElement(key) {
    for (const tr of doc.querySelectorAll("#tm-main tr[data-key]")) if (tr.dataset.key === key) return tr;
    return null;
  }

  /** `{section, sort}` of the header sort button `target` is in, or null. */
  function sortFocusOf(target) {
    const btn = typeof target.closest === "function" ? target.closest(".tm-sort") : null;
    const table = btn ? btn.closest("table[data-section]") : null;
    return table ? { section: table.dataset.section, sort: btn.dataset.sort } : null;
  }

  function sortButton(where) {
    const head = ui.tables[where.section] ? ui.tables[where.section].tHead : null;
    if (!head) return null;
    for (const btn of head.querySelectorAll(".tm-sort")) if (btn.dataset.sort === where.sort) return btn;
    return null;
  }

  function select(key, focus) {
    state.selected = key;
    for (const tr of doc.querySelectorAll("#tm-main tr[data-key]")) {
      const on = tr.dataset.key === key;
      tr.classList.toggle("is-selected", on);
      tr.setAttribute("aria-selected", on ? "true" : "false");
      tr.tabIndex = on ? 0 : -1;
    }
    const el = rowElement(key);
    if (el && focus) {
      el.focus();
      if (typeof el.scrollIntoView === "function") el.scrollIntoView({ block: "nearest" });
    }
  }

  function toggleExpanded(key, expand) {
    const row = rows.get(key);
    if (!row || !key.startsWith("tree|")) return;
    const has = state.collapsed.has(row.key);
    const want = expand === undefined ? has : expand;
    if (want === !has) return;
    if (want) state.collapsed.delete(row.key);
    else state.collapsed.add(row.key);
    render();
    select(key, true);
    saveState();
  }

  function openMenu(key, x, y) {
    const row = rows.get(key);
    if (!row) return;
    state.menuRow = row;
    const o = row.owner || {};
    const enable = { workspace: !!o.workspace_id, terminal: !!o.surface_id, kill: killPids(row).length > 0 };
    for (const btn of ui.menu.querySelectorAll(".tm-menu-item")) {
      btn.disabled = !enable[btn.dataset.action];
    }
    ui.menu.hidden = false;
    const view = doc.defaultView;
    const maxX = Math.max(0, (view ? view.innerWidth : 0) - (ui.menu.offsetWidth || 180));
    const maxY = Math.max(0, (view ? view.innerHeight : 0) - (ui.menu.offsetHeight || 100));
    ui.menu.style.setProperty("left", `${Math.max(0, Math.min(x, maxX))}px`);
    ui.menu.style.setProperty("top", `${Math.max(0, Math.min(y, maxY))}px`);
    const first = ui.menu.querySelector(".tm-menu-item:not(:disabled)");
    if (first) first.focus();
  }

  function closeMenu() {
    if (ui.menu.hidden) return;
    ui.menu.hidden = true;
    state.menuRow = null;
  }

  function runMenu(action) {
    const row = state.menuRow;
    closeMenu();
    if (!row) return;
    if (action === "workspace") viewWorkspace(row);
    else if (action === "terminal") viewTerminal(row);
    else if (action === "kill") kill(row);
  }

  function setSort(key) {
    if (state.sort.key === key) state.sort = { key, dir: state.sort.dir === "asc" ? "desc" : "asc" };
    else state.sort = { key, dir: defaultDirection(key) };
    render();
    saveState();
  }

  function setShowProcesses(on) {
    state.showProcesses = !!on;
    render();
    saveState();
  }

  /* ---------------------------------------------------------------------- */
  /* wiring                                                                 */
  /* ---------------------------------------------------------------------- */

  function rowKeyOf(target) {
    const tr = target && typeof target.closest === "function" ? target.closest("tr[data-key]") : null;
    return tr ? tr.dataset.key : null;
  }

  function onMainClick(e) {
    const sortBtn = e.target.closest(".tm-sort");
    if (sortBtn) {
      setSort(sortBtn.dataset.sort);
      return;
    }
    const key = rowKeyOf(e.target);
    if (!key) return;
    if (e.target.closest(".tm-toggle-row")) {
      toggleExpanded(key);
      return;
    }
    select(key, true);
  }

  function onMainDblClick(e) {
    const key = rowKeyOf(e.target);
    if (!key || e.target.closest(".tm-toggle-row")) return;
    activate(rows.get(key));
  }

  function onMainContextMenu(e) {
    e.preventDefault();
    const key = rowKeyOf(e.target);
    if (!key) return;
    select(key, true);
    openMenu(key, e.clientX, e.clientY);
  }

  function onMainKey(e) {
    const key = rowKeyOf(e.target);
    if (!key) return;
    const tr = rowElement(key);
    const body = tr.parentElement;
    const list = Array.from(body.querySelectorAll("tr[data-key]"));
    const pos = list.indexOf(tr);
    const plain = !e.ctrlKey && !e.altKey && !e.metaKey && !e.shiftKey;
    const row = rows.get(key);
    if ((e.key === "ArrowDown" || e.key === "ArrowUp") && plain) {
      const next = list[Math.min(Math.max(pos + (e.key === "ArrowDown" ? 1 : -1), 0), list.length - 1)];
      if (next) select(next.dataset.key, true);
    } else if ((e.key === "Home" || e.key === "End") && plain) {
      const next = e.key === "Home" ? list[0] : list[list.length - 1];
      if (next) select(next.dataset.key, true);
    } else if (e.key === "ArrowRight" && plain && key.startsWith("tree|")) {
      if (tr.getAttribute("aria-expanded") === "false") toggleExpanded(key, true);
      else if (tr.getAttribute("aria-expanded") === "true" && list[pos + 1])
        select(list[pos + 1].dataset.key, true);
    } else if (e.key === "ArrowLeft" && plain && key.startsWith("tree|")) {
      if (tr.getAttribute("aria-expanded") === "true") toggleExpanded(key, false);
      else {
        const level = Number(tr.getAttribute("aria-level"));
        for (let i = pos - 1; i >= 0; i -= 1) {
          if (Number(list[i].getAttribute("aria-level")) < level) {
            select(list[i].dataset.key, true);
            break;
          }
        }
      }
    } else if (e.key === "Enter" && plain) {
      activate(row);
    } else if (e.key === "Delete" && plain) {
      if (killPids(row).length) kill(row);
    } else if (e.key === "ContextMenu" || (e.key === "F10" && e.shiftKey && !e.ctrlKey && !e.altKey)) {
      const r = tr.getBoundingClientRect();
      openMenu(key, r.left + 16, r.bottom);
    } else {
      return;
    }
    e.preventDefault();
  }

  function onMenuKey(e) {
    const items = Array.from(ui.menu.querySelectorAll(".tm-menu-item:not(:disabled)"));
    const pos = items.indexOf(doc.activeElement);
    if (e.key === "Escape") {
      const key = state.selected;
      closeMenu();
      if (key) select(key, true);
    } else if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      const next = items[(pos + (e.key === "ArrowDown" ? 1 : -1) + items.length) % items.length];
      if (next) next.focus();
    } else {
      return;
    }
    e.preventDefault();
    e.stopPropagation();
  }

  function wireDom() {
    listen(ui.main, "click", onMainClick);
    listen(ui.main, "dblclick", onMainDblClick);
    listen(ui.main, "contextmenu", onMainContextMenu);
    listen(ui.main, "keydown", onMainKey);
    listen(ui.refresh, "click", () => refresh());
    listen(ui.processes, "change", () => setShowProcesses(ui.processes.checked));
    listen(ui.menu, "click", (e) => {
      const btn = e.target.closest(".tm-menu-item");
      if (btn && !btn.disabled) runMenu(btn.dataset.action);
    });
    listen(ui.menu, "keydown", onMenuKey);
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
    listen(doc, "contextmenu", (e) => e.preventDefault());
    listen(doc, "visibilitychange", onVisibility);
  }

  function wireBridge() {
    cleanups.push(bridge.on("panel.task_manager.refresh", () => refresh()));
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
    render();
    if (!bridge.available) return api;

    let ctx = null;
    try {
      ctx = await bridge.ready(
        options.readyTimeoutMs !== undefined ? { timeoutMs: options.readyTimeoutMs } : undefined,
      );
    } catch (err) {
      console.warn("[task-manager] panel.ready failed:", errorMessage(err));
    }
    if (state.destroyed) return api;
    if (bridge.context) ctx = bridge.context;
    restoreState(ctx && ctx.state);
    const params = ctx && ctx.params && typeof ctx.params === "object" ? ctx.params : {};
    if (typeof params.processes === "boolean") state.showProcesses = params.processes;
    doc.title = t("tm.title");
    bridge.panel.setTitle(t("tm.title")).catch(() => {});
    render();
    await refresh();
    return api;
  }

  function destroy() {
    state.destroyed = true;
    cancelTimer();
    if (state.confirmResolve) state.confirmResolve(false);
    for (const fn of cleanups.splice(0)) {
      try {
        fn();
      } catch {
        // ignore
      }
    }
  }

  const api = {
    start,
    destroy,
    refresh,
    activate,
    viewWorkspace,
    viewTerminal,
    kill,
    setSort,
    setShowProcesses,
    toggleExpanded,
    row: (key) => rows.get(key) || null,
    get sort() {
      return { ...state.sort };
    },
    get top() {
      return state.top;
    },
    get scheduled() {
      return state.timer !== null;
    },
    get busy() {
      return state.busy;
    },
  };
  return api;
}
