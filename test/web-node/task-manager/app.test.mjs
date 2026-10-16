// Task Manager tests: node:test + jsdom driving src/web/task-manager/app.js
// against a mock host answering system.top / system.memory and the jump and
// kill methods. The page harness is shared with the todo tests.
import { test, describe, afterEach, after } from "node:test";
import assert from "node:assert/strict";
import { setupPage, hostError, settle, key, click, mouse, cspOf } from "../todo/harness.mjs";
import { topReply, memoryReply, IDS } from "./fixture.mjs";

const page = await setupPage("task-manager");
const { window, doc, host, importWeb, pristineBody } = page;
const { createApp, REFRESH_MS } = await importWeb("task-manager/app.js");

let app = null;
let top = null;
let hidden = false;
Object.defineProperty(doc, "visibilityState", {
  configurable: true,
  get: () => (hidden ? "hidden" : "visible"),
});

function setHidden(v) {
  hidden = v;
  doc.dispatchEvent(new window.Event("visibilitychange"));
}

async function startApp({ init = {}, handlers = {}, refreshMs = 60000 } = {}) {
  if (app) app.destroy();
  doc.body.innerHTML = pristineBody;
  host.reset();
  hidden = false;
  top = topReply();
  const base = {
    "panel.ready": () => ({}),
    "panel.set_title": () => ({}),
    "panel.state_changed": () => ({}),
    "system.top": () => top,
    "system.memory": () => memoryReply(),
    "workspace.select": () => ({}),
    "surface.focus": () => ({}),
    "window.focus": () => ({}),
    "pane.focus": () => ({}),
    "panel.task_manager.kill": ({ pids }) => {
      // The sleep row disappears once killed.
      if (pids.includes(4242)) top.windows[1].workspaces[0].panes[0].surfaces[0].processes = [];
      return { killed: pids };
    },
    ...handlers,
  };
  for (const [method, fn] of Object.entries(base)) host.handlers.set(method, fn);
  host.emit("panel.init", {
    kind: "task_manager",
    surface_id: "5B1D2C9E-0000-4000-8000-000000000003",
    params: {},
    state: null,
    theme: { background: "#1e1e1e", foreground: "#d4d4d4" },
    settings: {},
    ...init,
  });
  app = createApp({ document: doc, refreshMs, now: () => new Date(2026, 9, 16, 9, 5, 7) });
  await app.start();
  await settle();
  return app;
}

const $ = (id) => doc.getElementById(id);
const bodyRows = (id) => Array.from($(id).tBodies[0].rows);
const names = (id) => bodyRows(id).map((tr) => tr.querySelector(".tm-name").textContent);
const treeRow = (pred) => bodyRows("tm-tree").find((tr) => pred(app.row(tr.dataset.key), tr));
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

/** Poll `pred` until it holds or `ms` pass (timing tests on a loaded machine). */
async function waitFor(pred, ms = 5000) {
  const end = Date.now() + ms;
  while (!pred() && Date.now() < end) await wait(10);
  return pred();
}

after(() => window.close());
afterEach(() => {
  if (app) {
    app.destroy();
    app = null;
  }
});

describe("unit: task manager basics", () => {
  test("unit: task-manager: page has a strict CSP and no inline script or style", () => {
    const csp = cspOf(page.html);
    assert.match(csp, /default-src 'self'/);
    assert.match(csp, /script-src 'self'/);
    assert.match(csp, /trusted-types 'none'/);
    assert.doesNotMatch(csp, /unsafe-inline|unsafe-eval|https?:\/\//);
    assert.doesNotMatch(page.html, /<script(?![^>]*src=)|style="|<style|\son[a-z]+=/i);
  });

  test("unit: task-manager: every data-i18n key in index.html is in strings.js with the same text", async () => {
    const { STRINGS } = await importWeb("task-manager/strings.js");
    const tpl = new window.DOMParser().parseFromString(page.html, "text/html");
    const keyed = tpl.querySelectorAll("[data-i18n]");
    assert.ok(keyed.length > 0);
    for (const el of keyed) {
      assert.equal(el.textContent.trim(), STRINGS[el.dataset.i18n], el.dataset.i18n);
    }
    for (const el of tpl.querySelectorAll("[data-i18n-attr]")) {
      for (const pair of el.dataset.i18nAttr.split(";")) {
        const [attr, k] = pair.split(":").map((s) => s.trim());
        assert.equal(el.getAttribute(attr), STRINGS[k], `${attr}:${k}`);
      }
    }
  });

  test("unit: task-manager: loads system.top and system.memory into cards and sections", async () => {
    await startApp();
    assert.deepEqual(host.calls("panel.set_title")[0].params, { title: "Task Manager" });
    assert.deepEqual(host.calls("system.top")[0].params, { all_windows: true, include_processes: true });
    assert.deepEqual(host.calls("system.memory")[0].params, { all_windows: true });
    assert.equal($("tm-card-cpu").textContent, "130.5%");
    assert.equal($("tm-card-memory").textContent, "905 MB");
    assert.equal($("tm-card-app").textContent, "250 MB");
    assert.equal($("tm-card-child").textContent, "705 MB");
    assert.equal($("tm-card-processes").textContent, "7");
    assert.equal($("tm-card-updated").textContent, "09:05:07");
    assert.equal($("tm-state").hidden, true);
    assert.equal($("tm-main").hidden, false);
    assert.deepEqual(names("tm-agents"), ["Claude Code"]);
    assert.equal(bodyRows("tm-agents")[0].querySelector(".tm-col-cpu").textContent, "119.8%");
    assert.equal(names("tm-programs")[0], "claude.exe", "heaviest CPU first by default");
    assert.deepEqual(names("tm-child"), ["claude", "node", "sleep"]);
    assert.equal(bodyRows("tm-child")[0].querySelector(".tm-col-cpu").textContent, "");
    // Header columns.
    const heads = Array.from($("tm-tree").tHead.querySelectorAll(".tm-sort")).map((b) => b.textContent);
    assert.deepEqual(heads, ["Name", "CPU", "Memory", "Proc"]);
  });

  test("unit: task-manager: hierarchy shows windows, workspaces, panes, surfaces and webviews", async () => {
    await startApp();
    const tree = names("tm-tree");
    assert.deepEqual(tree.slice(0, 4), ["Window window:1", "api <server>", 'build "watch"', "Pane pane:1"]);
    assert.ok(tree.includes("pwsh"));
    assert.ok(tree.includes("docs.example"), "browser webview row");
    assert.ok(!tree.includes("claude.exe"), "process rows hidden until Processes is on");
    const ws = treeRow((r) => r.kind === "workspace" && r.title === "docs");
    assert.equal(ws.querySelector(".tm-detail").textContent, "pinned");
    const surface = treeRow((r) => r.kind === "surface" && r.type === "terminal" && r.title === "pwsh");
    assert.equal(surface.querySelector(".tm-detail").textContent, "terminal · selected · conpty-1");
    assert.equal(surface.getAttribute("aria-level"), "4");
    const hiddenWin = treeRow((r) => r.kind === "window" && r.ref === "window:2");
    assert.equal(hiddenWin.querySelector(".tm-detail").textContent, "hidden");
    // cmux top: `window <ref> [key] [hidden]`.
    const keyWin = treeRow((r) => r.kind === "window" && r.ref === "window:1");
    assert.equal(keyWin.querySelector(".tm-detail").textContent, "key");
    const tag = treeRow((r) => r.kind === "tag");
    assert.equal(tag.querySelector(".tm-detail").textContent, "PID 501", "a tag's key is not a flag");
    // Titles are text, never markup.
    assert.equal(doc.querySelector("#tm-tree b, #tm-tree server"), null);
  });

  test("unit: task-manager: the Processes toggle adds process rows and is saved", async () => {
    await startApp();
    $("tm-processes").checked = true;
    $("tm-processes").dispatchEvent(new window.Event("change", { bubbles: true }));
    const proc = treeRow((r) => r.kind === "process" && r.pid === 200);
    assert.ok(proc);
    assert.equal(proc.querySelector(".tm-name").textContent, "claude.exe");
    assert.equal(proc.querySelector(".tm-detail").textContent, "PID 200 · Claude Code");
    assert.equal(proc.getAttribute("aria-level"), "6");
    const saved = host.calls("panel.state_changed").at(-1).params.state;
    assert.equal(saved.show_processes, true);
  });

  test("unit: task-manager: restored state brings back processes, sort and collapsed rows", async () => {
    await startApp({
      init: {
        state: {
          v: 1,
          show_processes: true,
          sort: { key: "mem", dir: "asc" },
          collapsed: [`window:${IDS.win1}`],
        },
      },
    });
    assert.equal($("tm-processes").checked, true);
    assert.deepEqual(app.sort, { key: "mem", dir: "asc" });
    assert.deepEqual(names("tm-tree"), [
      "Window window:2",
      "idle",
      "Pane pane:3",
      "sleep",
      "sleep",
      "Window window:1",
    ]);
  });
});

describe("unit: task manager sorting and refresh", () => {
  test("unit: task-manager: column headers sort siblings and flip direction", async () => {
    await startApp();
    const sortBtn = (s) => $("tm-tree").tHead.querySelector(`.tm-sort[data-sort="${s}"]`);
    click(window, sortBtn("cpu"));
    assert.deepEqual(app.sort, { key: "cpu", dir: "desc" });
    assert.equal(sortBtn("cpu").parentElement.getAttribute("aria-sort"), "descending");
    let wsNames = bodyRows("tm-tree")
      .filter((tr) => tr.dataset.kind === "workspace")
      .map((tr) => tr.querySelector(".tm-name").textContent);
    assert.deepEqual(wsNames, ["api <server>", "docs", "idle"]);
    click(window, sortBtn("cpu"));
    assert.deepEqual(app.sort, { key: "cpu", dir: "asc" });
    assert.deepEqual(names("tm-tree").slice(0, 1), ["Window window:2"]);
    wsNames = bodyRows("tm-tree")
      .filter((tr) => tr.dataset.kind === "workspace")
      .map((tr) => tr.querySelector(".tm-name").textContent);
    assert.deepEqual(wsNames, ["idle", "docs", "api <server>"]);
    // Name ascends first; the sort applies to every section.
    click(window, $("tm-child").tHead.querySelector('.tm-sort[data-sort="name"]'));
    assert.deepEqual(app.sort, { key: "name", dir: "asc" });
    assert.deepEqual(names("tm-child"), ["claude", "node", "sleep"]);
    click(window, $("tm-child").tHead.querySelector('.tm-sort[data-sort="proc"]'));
    assert.deepEqual(app.sort, { key: "proc", dir: "desc" });
    assert.deepEqual(host.calls("panel.state_changed").at(-1).params.state.sort, {
      key: "proc",
      dir: "desc",
    });
  });

  test("unit: task-manager: auto-refreshes every 3 s while visible and stops when hidden", async () => {
    assert.equal(REFRESH_MS, 3000);
    await startApp();
    assert.equal(app.scheduled, true);
    app.destroy();
    await startApp({ refreshMs: 30 });
    const n0 = host.calls("system.top").length;
    // jsdom renders slowly (and CI machines are busy): wait for a few cycles
    // of the 30 ms cadence instead of a fixed time.
    await waitFor(() => host.calls("system.top").length >= n0 + 2);
    const n1 = host.calls("system.top").length;
    assert.ok(n1 >= n0 + 2, `expected repeated refreshes, got ${n1 - n0}`);
    setHidden(true);
    await settle();
    assert.equal(app.scheduled, false);
    const n2 = host.calls("system.top").length;
    await wait(200);
    assert.equal(host.calls("system.top").length, n2, "no refresh while hidden");
    setHidden(false);
    await settle();
    assert.equal(host.calls("system.top").length, n2 + 1, "refreshes at once when shown");
    assert.equal(app.scheduled, true);
  });

  test("unit: task-manager: Refresh forces an update and concurrent refreshes coalesce", async () => {
    let release;
    let slow = false;
    await startApp({
      handlers: {
        "system.top": () => (slow ? new Promise((r) => (release = () => r(top))) : top),
      },
    });
    slow = true;
    const n = host.calls("system.top").length;
    click(window, $("tm-refresh"));
    await settle(2);
    assert.equal($("tm-refreshing").hidden, false, "refreshing indicator");
    app.refresh();
    host.emit("panel.task_manager.refresh", {});
    await settle(2);
    assert.equal(host.calls("system.top").length, n + 1);
    release();
    await settle();
    assert.equal($("tm-refreshing").hidden, true);
  });

  test("unit: task-manager: keyboard focus stays on its row across refreshes", async () => {
    await startApp();
    const tr = treeRow((r) => r.kind === "workspace" && r.title === "docs");
    click(window, tr);
    assert.equal(doc.activeElement, tr);
    await app.refresh();
    await settle();
    assert.equal(doc.activeElement.dataset.key, tr.dataset.key);
    assert.notEqual(doc.activeElement, tr, "the row element was rebuilt");
    assert.ok(doc.activeElement.classList.contains("is-selected"));
  });

  test("unit: task-manager: a focused column header keeps focus across sorting and refreshes", async () => {
    await startApp();
    const sortBtn = (id, s) => $(id).tHead.querySelector(`.tm-sort[data-sort="${s}"]`);
    // WebView2 focuses a button on click; keyboard users Tab to it.
    sortBtn("tm-tree", "mem").focus();
    click(window, sortBtn("tm-tree", "mem"));
    assert.deepEqual(app.sort, { key: "mem", dir: "desc" });
    assert.equal(doc.activeElement, sortBtn("tm-tree", "mem"), "the rebuilt header button has focus");
    await app.refresh();
    await settle();
    assert.equal(doc.activeElement, sortBtn("tm-tree", "mem"), "the 3 s refresh does not drop it");
    sortBtn("tm-programs", "name").focus();
    await app.refresh();
    await settle();
    assert.equal(doc.activeElement, sortBtn("tm-programs", "name"));
  });
});

describe("unit: task manager states", () => {
  test("unit: task-manager: loading, then empty state", async () => {
    let resolve;
    const pending = startApp({ handlers: { "system.top": () => new Promise((r) => (resolve = r)) } });
    await settle(3);
    assert.equal($("tm-state-title").textContent, "Loading resource usage");
    assert.equal($("tm-main").hidden, true);
    resolve({ windows: [{ id: IDS.win1, ref: "window:1" }], totals: {} });
    await pending;
    await settle();
    assert.equal($("tm-state-title").textContent, "No resource usage");
    assert.equal(
      $("tm-state-body").textContent,
      "Open a workspace, terminal, or browser surface to see it here.",
    );
    assert.equal($("tm-main").hidden, true);
  });

  test("unit: task-manager: first-load failure and unsupported builds", async () => {
    await startApp({
      handlers: {
        "system.top": () => {
          throw hostError("internal_error", "sampler crashed");
        },
      },
    });
    assert.equal($("tm-state-title").textContent, "Unable to load resource usage");
    assert.equal($("tm-state-body").textContent, "sampler crashed");
    await startApp({
      handlers: {
        "system.top": () => {
          throw hostError("method_not_found", "Unknown method");
        },
      },
    });
    assert.equal($("tm-state-body").textContent, "This wmux build does not support process diagnostics.");
    await startApp({ handlers: { "system.top": () => ({ nope: 1 }) } });
    assert.equal($("tm-state-title").textContent, "Unable to load resource usage");
  });

  test("unit: task-manager: later failures keep the data and show the refresh banner", async () => {
    let fail = null;
    await startApp({
      handlers: {
        "system.top": () => {
          if (fail) throw fail;
          return top;
        },
      },
    });
    fail = hostError("rate_limited", "slow down");
    await app.refresh();
    await settle();
    assert.equal($("tm-banner").hidden, true, "rate limiting is silent");
    fail = hostError("timeout", "main actor busy");
    await app.refresh();
    await settle();
    assert.equal($("tm-banner").textContent, "Unable to refresh Task Manager data.");
    assert.equal($("tm-main").hidden, false);
    assert.ok(names("tm-tree").length > 0);
    fail = null;
    await app.refresh();
    await settle();
    assert.equal($("tm-banner").hidden, true);
  });

  test("unit: task-manager: system.memory failures only blank the memory cards", async () => {
    await startApp({
      handlers: {
        "system.memory": () => {
          throw hostError("method_not_found", "x");
        },
      },
    });
    assert.equal($("tm-card-app").textContent, "—");
    assert.equal($("tm-card-child").textContent, "—");
    assert.equal($("tm-card-cpu").textContent, "130.5%");
    assert.equal($("tm-child-none").hidden, false);
    assert.equal($("tm-child").hidden, true);
  });
});

describe("unit: task manager actions", () => {
  test("unit: task-manager: double-click and Enter jump to the owner", async () => {
    await startApp();
    const surface = treeRow((r) => r.kind === "surface" && r.title === "pwsh");
    mouse(window, surface.querySelector(".tm-name"), "dblclick");
    await settle();
    assert.deepEqual(host.calls("surface.focus")[0].params, {
      surface_id: IDS.surfTerm,
      window_id: IDS.win1,
      workspace_id: IDS.wsApi,
    });
    const ws = treeRow((r) => r.kind === "workspace" && r.title === "docs");
    click(window, ws);
    key(window, ws, { key: "Enter" });
    await settle();
    assert.deepEqual(host.calls("workspace.select")[0].params, {
      workspace_id: IDS.wsWeb,
      window_id: IDS.win1,
    });
    const win = treeRow((r) => r.kind === "window" && r.ref === "window:2");
    mouse(window, win, "dblclick");
    await settle();
    assert.deepEqual(host.calls("window.focus")[0].params, { window_id: IDS.win2 });
    const pane = treeRow((r) => r.kind === "pane" && r.ref === "pane:1");
    mouse(window, pane, "dblclick");
    await settle();
    assert.deepEqual(host.calls("pane.focus")[0].params, {
      pane_id: IDS.pane1,
      window_id: IDS.win1,
      workspace_id: IDS.wsApi,
    });
    // An agent row jumps to its terminal.
    mouse(window, bodyRows("tm-agents")[0], "dblclick");
    await settle();
    assert.equal(host.calls("surface.focus").length, 2);
  });

  test("unit: task-manager: context menu View Workspace and View Terminal", async () => {
    await startApp();
    const surface = treeRow((r) => r.kind === "surface" && r.title === "Docs");
    mouse(window, surface, "contextmenu", { clientX: 20, clientY: 20 });
    const menu = $("tm-menu");
    assert.equal(menu.hidden, false);
    const item = (a) => menu.querySelector(`[data-action="${a}"]`);
    assert.deepEqual(
      Array.from(menu.querySelectorAll(".tm-menu-item")).map((b) => b.textContent),
      ["View Workspace", "View Terminal", "Kill Process..."],
    );
    assert.equal(item("workspace").disabled, false);
    assert.equal(item("terminal").disabled, false);
    assert.equal(item("kill").disabled, true, "browser surfaces have no killable processes");
    click(window, item("workspace"));
    await settle();
    assert.equal(menu.hidden, true);
    assert.deepEqual(host.calls("workspace.select")[0].params, {
      workspace_id: IDS.wsWeb,
      window_id: IDS.win1,
    });
    mouse(window, surface, "contextmenu");
    click(window, item("terminal"));
    await settle();
    assert.deepEqual(host.calls("surface.focus")[0].params, {
      surface_id: IDS.surfBrowser,
      window_id: IDS.win1,
      workspace_id: IDS.wsWeb,
    });
    // Windows offer nothing but stay keyboard reachable; Escape closes.
    mouse(
      window,
      treeRow((r) => r.kind === "window"),
      "contextmenu",
    );
    assert.equal(item("workspace").disabled, true);
    key(window, menu, { key: "Escape" });
    assert.equal(menu.hidden, true);
  });

  test("unit: task-manager: Kill Process confirms, kills gracefully and refreshes", async () => {
    await startApp({ init: { state: { show_processes: true } } });
    const sleep = treeRow((r) => r.kind === "process" && r.pid === 4242);
    mouse(window, sleep, "contextmenu");
    click(window, $("tm-menu").querySelector('[data-action="kill"]'));
    assert.equal($("tm-confirm").hidden, false);
    assert.equal($("tm-confirm-title").textContent, "Kill process?");
    assert.equal(
      $("tm-confirm-text").textContent,
      "Ask sleep (PID 4242) to terminate gracefully. wmux will force-kill it if it is still running after a short grace period.",
    );
    assert.equal(doc.activeElement, $("tm-confirm-cancel"));
    const before = host.calls("system.top").length;
    click(window, $("tm-confirm-ok"));
    await settle();
    assert.deepEqual(host.calls("panel.task_manager.kill")[0].params, { pids: [4242] });
    assert.equal(host.calls("system.top").length, before + 1);
    assert.equal(
      treeRow((r) => r.kind === "process" && r.pid === 4242),
      undefined,
    );
    assert.equal($("tm-confirm").hidden, true);
  });

  test("unit: task-manager: Escape or Cancel never kills; plural lists PIDs", async () => {
    await startApp();
    const ws = treeRow((r) => r.kind === "workspace" && r.title === "api <server>");
    click(window, ws);
    key(window, ws, { key: "Delete" });
    assert.equal($("tm-confirm").hidden, false);
    assert.equal(
      $("tm-confirm-text").textContent,
      "Ask 2 processes (PIDs 501, 100) to terminate gracefully. wmux will force-kill them if they are still running after a short grace period.",
    );
    key(window, $("tm-confirm-cancel"), { key: "Escape" });
    await settle();
    assert.equal($("tm-confirm").hidden, true);
    const surface = treeRow((r) => r.kind === "surface" && r.title === "pwsh");
    mouse(window, surface, "contextmenu");
    click(window, $("tm-menu").querySelector('[data-action="kill"]'));
    assert.match($("tm-confirm-text").textContent, /^Ask pwsh\.exe \(PID 100\)/);
    click(window, $("tm-confirm-cancel"));
    await settle();
    assert.equal(host.calls("panel.task_manager.kill").length, 0);
  });

  test("unit: task-manager: kill errors are reported", async () => {
    await startApp({
      handlers: {
        "panel.task_manager.kill": () => {
          throw hostError("forbidden", "Access is denied.");
        },
      },
    });
    const done = app.kill(app.row(treeRow((r) => r.kind === "tag").dataset.key));
    await settle(2);
    assert.match($("tm-confirm-text").textContent, /^Ask build \(PID 501\)/);
    click(window, $("tm-confirm-ok"));
    assert.equal(await done, false);
    assert.equal($("tm-banner").textContent, "Unable to kill process: Access is denied.");
    host.handlers.set("panel.task_manager.kill", () => ({
      failed: [{ pid: 501, message: "process is protected" }],
    }));
    const again = app.kill(app.row(treeRow((r) => r.kind === "tag").dataset.key));
    await settle(2);
    click(window, $("tm-confirm-ok"));
    assert.equal(await again, false);
    assert.equal($("tm-banner").textContent, "Unable to kill process: process is protected");
  });

  test("unit: task-manager: a PID listed in two places gives two rows with their own owners", async () => {
    await startApp({ init: { state: { show_processes: true } } });
    // The status-tag process 501 (window 1) also runs in the idle terminal (window 2).
    top.windows[1].workspaces[0].panes[0].surfaces[0].processes.push({
      pid: 501,
      name: "watcher.exe",
      cpu_percent: 0.5,
      memory_bytes: 1024,
    });
    await app.refresh();
    await settle();
    const dupes = bodyRows("tm-tree").filter((tr) => {
      const r = app.row(tr.dataset.key);
      return r.kind === "process" && r.pid === 501;
    });
    assert.equal(dupes.length, 2);
    assert.notEqual(dupes[0].dataset.key, dupes[1].dataset.key, "row keys are unique");
    click(window, dupes[0]);
    assert.equal(doc.querySelectorAll("#tm-tree tr.is-selected").length, 1);
    // The tag's copy has no surface: it jumps to its workspace in window 1.
    mouse(window, dupes[0], "dblclick");
    await settle();
    assert.deepEqual(host.calls("workspace.select").at(-1).params, {
      workspace_id: IDS.wsApi,
      window_id: IDS.win1,
    });
    assert.equal(host.calls("surface.focus").length, 0);
    // The terminal's copy jumps to that terminal.
    mouse(window, dupes[1], "dblclick");
    await settle();
    assert.deepEqual(host.calls("surface.focus").at(-1).params, {
      surface_id: IDS.surfSleep,
      window_id: IDS.win2,
      workspace_id: IDS.wsIdle,
    });
    // Arrow keys move from the row that has focus, not from its twin.
    click(window, dupes[1]);
    const list = bodyRows("tm-tree");
    key(window, dupes[1], { key: "ArrowUp" });
    assert.equal(doc.activeElement, list[list.indexOf(dupes[1]) - 1]);
  });

  test("unit: task-manager: every table is reachable with Tab and focusing a row selects it", async () => {
    await startApp();
    for (const id of ["tm-agents", "tm-programs", "tm-child", "tm-tree"]) {
      const stops = bodyRows(id).filter((tr) => tr.tabIndex === 0);
      assert.deepEqual(stops, [bodyRows(id)[0]], `${id} has one tab stop: its first row`);
    }
    // Tab lands on a row: it becomes the selection, and arrows work from there.
    const agent = bodyRows("tm-agents")[0];
    agent.focus();
    assert.equal(agent.getAttribute("aria-selected"), "true");
    assert.equal(bodyRows("tm-tree")[0].tabIndex, 0, "other tables keep their tab stop");
    const tree = bodyRows("tm-tree");
    tree[0].focus();
    key(window, tree[0], { key: "ArrowDown" });
    assert.equal(doc.activeElement, bodyRows("tm-tree")[1]);
    assert.equal(bodyRows("tm-tree")[1].tabIndex, 0);
    assert.equal(bodyRows("tm-tree")[0].tabIndex, -1);
    // The tab stops survive a refresh.
    await app.refresh();
    await settle();
    assert.equal(bodyRows("tm-agents").filter((tr) => tr.tabIndex === 0).length, 1);
    assert.equal(doc.activeElement.dataset.key, bodyRows("tm-tree")[1].dataset.key);
  });

  test("unit: task-manager: the kill confirmation is modal and gives focus back to the row", async () => {
    await startApp();
    const ws = treeRow((r) => r.kind === "workspace" && r.title === "api <server>");
    click(window, ws);
    key(window, ws, { key: "Delete" });
    assert.equal(doc.activeElement, $("tm-confirm-cancel"));
    const others = Array.from(doc.body.children).filter((el) => el !== $("tm-confirm"));
    assert.ok(
      others.every((el) => el.hasAttribute("inert")),
      "the page behind the dialog is inert",
    );
    key(window, $("tm-confirm-cancel"), { key: "Escape" });
    await settle();
    assert.equal(doc.querySelectorAll("[inert]").length, 0);
    assert.equal(doc.activeElement.dataset.key, ws.dataset.key, "focus is back on the row");
  });

  test("unit: task-manager: when the focused row goes away focus moves to its neighbour", async () => {
    await startApp({ init: { state: { show_processes: true } } });
    const sleep = treeRow((r) => r.kind === "process" && r.pid === 4242);
    click(window, sleep);
    key(window, sleep, { key: "Delete" });
    click(window, $("tm-confirm-ok"));
    await settle();
    assert.deepEqual(host.calls("panel.task_manager.kill")[0].params, { pids: [4242] });
    assert.equal(
      treeRow((r) => r.kind === "process" && r.pid === 4242),
      undefined,
    );
    const active = doc.activeElement;
    assert.ok(active && active.matches("#tm-tree tr[data-key]"), "focus stays in the Hierarchy");
    assert.equal(active.getAttribute("aria-selected"), "true");
    key(window, active, { key: "ArrowUp" });
    assert.ok(doc.activeElement.matches("#tm-tree tr[data-key]"));
  });

  test("unit: task-manager: arrow keys move, Left/Right collapse and expand", async () => {
    await startApp();
    const first = bodyRows("tm-tree")[0];
    click(window, first);
    key(window, first, { key: "ArrowDown" });
    assert.equal(doc.activeElement, bodyRows("tm-tree")[1]);
    key(window, doc.activeElement, { key: "ArrowLeft" });
    key(window, doc.activeElement, { key: "ArrowLeft" });
    assert.equal(doc.activeElement.dataset.kind, "window");
    key(window, doc.activeElement, { key: "ArrowLeft" });
    assert.equal(doc.activeElement.getAttribute("aria-expanded"), "false");
    assert.deepEqual(names("tm-tree").slice(0, 2), ["Window window:1", "Window window:2"]);
    key(window, doc.activeElement, { key: "ArrowRight" });
    assert.equal(doc.activeElement.getAttribute("aria-expanded"), "true");
    key(window, doc.activeElement, { key: "ArrowRight" });
    assert.equal(doc.activeElement.dataset.kind, "workspace");
    key(window, doc.activeElement, { key: "End" });
    assert.equal(doc.activeElement, bodyRows("tm-tree").at(-1));
    // Clicking the disclosure toggles too.
    click(window, bodyRows("tm-tree")[0].querySelector(".tm-toggle-row"));
    assert.equal(bodyRows("tm-tree")[0].getAttribute("aria-expanded"), "false");
  });
});

test("unit: task-manager: outside wmux it shows the offline state and never polls", async () => {
  if (app) app.destroy();
  doc.body.innerHTML = pristineBody;
  const offline = {
    available: false,
    context: null,
    on: () => () => {},
    call: () => Promise.reject(new Error("x")),
  };
  app = createApp({ document: doc, bridge: offline });
  await app.start();
  assert.equal($("tm-state-title").textContent, "Not running inside wmux.");
  assert.equal(app.scheduled, false);
});
