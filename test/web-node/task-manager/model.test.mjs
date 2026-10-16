// Task Manager model tests (pure, no DOM): src/web/task-manager/model.js.
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { topReply, memoryReply, IDS, MB } from "./fixture.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const web = path.resolve(here, "../../../src/web");
const m = await import(pathToFileURL(path.join(web, "task-manager/model.js")).href);

describe("unit: task manager model", () => {
  test("unit: task-manager: normalizes the system.top tree with kinds, owners and keys", () => {
    const top = m.normalizeTop(topReply());
    assert.equal(top.windows.length, 2);
    assert.deepEqual(top.totals, { cpu: 130.5, mem: 905 * MB, proc: 7 });
    const [w1, w2] = top.windows;
    assert.equal(w1.kind, "window");
    assert.equal(w1.key, `window:${IDS.win1}`);
    assert.equal(w2.flags.hidden, true);
    const ws = w1.children[0];
    assert.equal(ws.kind, "workspace");
    assert.equal(ws.title, "api <server>");
    assert.deepEqual(
      ws.children.map((c) => c.kind),
      ["tag", "pane"],
    );
    const surface = ws.children[1].children[0];
    assert.equal(surface.kind, "surface");
    assert.equal(surface.type, "terminal");
    assert.deepEqual(surface.owner, {
      window_id: IDS.win1,
      workspace_id: IDS.wsApi,
      pane_id: IDS.pane1,
      surface_id: IDS.surfTerm,
    });
    const pwsh = surface.children[0];
    assert.equal(pwsh.kind, "process");
    assert.equal(pwsh.pid, 100);
    assert.equal(pwsh.proc, 4, "process_count defaults to the subtree size");
    assert.equal(pwsh.owner.surface_id, IDS.surfTerm);
    const claude = pwsh.children[0];
    assert.equal(claude.agent, "Claude Code");
    assert.equal(claude.children[0].kind, "process");
    const webview = w1.children[1].children[0].children[0].children[0];
    assert.equal(webview.kind, "webview");
    assert.equal(webview.pid, 900);
    // Window without totals: summed.
    const sum = m.normalizeTop({
      windows: [{ cpu_percent: 1, memory_bytes: 2, process_count: 3 }, { cpu_percent: "4" }],
    });
    assert.deepEqual(sum.totals, { cpu: 5, mem: 2, proc: 3 });
  });

  test("unit: task-manager: malformed replies are rejected or sanitized", () => {
    assert.equal(m.normalizeTop(null), null);
    assert.equal(m.normalizeTop({}), null);
    assert.equal(m.normalizeTop({ windows: "x" }), null);
    const top = m.normalizeTop({
      windows: [
        null,
        5,
        { cpu_percent: -3, memory_bytes: "NaN", process_count: Infinity, workspaces: [{ panes: "nope" }] },
      ],
    });
    assert.equal(top.windows.length, 1);
    assert.deepEqual([top.windows[0].cpu, top.windows[0].mem, top.windows[0].proc], [0, 0, 0]);
    assert.equal(top.windows[0].children[0].children.length, 0);
    assert.equal(m.hasUsage(top), true);
    assert.equal(m.hasUsage(m.normalizeTop({ windows: [{ id: "w" }] })), false);
    assert.equal(m.hasUsage(m.normalizeTop({ windows: [] })), false);
    // Bad PIDs are dropped, not trusted.
    const p = m.normalizeTop({
      windows: [{ processes: [{ pid: -1, name: "x" }, { pid: "12", name: "y" }, { pid: 1.5 }] }],
    });
    assert.deepEqual(
      p.windows[0].children.map((c) => c.pid),
      [null, 12, null],
    );
  });

  test("unit: task-manager: agents are detected by name or explicit field, outermost only", () => {
    assert.equal(m.agentName({ name: "C:\\Tools\\Claude.EXE" }), "Claude Code");
    assert.equal(m.agentName({ name: "codex" }), "Codex");
    assert.equal(m.agentName({ name: "opencode.exe" }), "OpenCode");
    assert.equal(m.agentName({ name: "node.exe", agent: "claude" }), "Claude Code");
    assert.equal(m.agentName({ name: "node.exe", agent: "MyBot" }), "MyBot");
    assert.equal(m.agentName({ name: "node.exe" }), "");
    assert.equal(m.agentName(null), "");
    const top = m.normalizeTop(topReply());
    const agents = m.codingAgents(top);
    assert.equal(agents.length, 1);
    assert.equal(agents[0].title, "Claude Code");
    assert.equal(agents[0].detail, "api <server>");
    assert.equal(agents[0].pid, 200);
    assert.deepEqual(agents[0].pids, [200, 300, 301]);
    assert.equal(agents[0].proc, 3);
    assert.equal(agents[0].mem, 600 * MB);
    assert.ok(Math.abs(agents[0].cpu - 119.8) < 1e-9, "CPU can exceed 100% across cores");
    assert.equal(agents[0].owner.surface_id, IDS.surfTerm);
  });

  test("unit: task-manager: row keys stay unique when PIDs repeat", () => {
    const reply = topReply();
    // Process 501 under its status tag and in a terminal; two browser surfaces
    // whose webviews report the shared WebView2 browser process and no id.
    reply.windows[1].workspaces[0].panes[0].surfaces[0].processes.push({ pid: 501, name: "watcher.exe" });
    const browser = reply.windows[0].workspaces[1].panes[0].surfaces[0];
    reply.windows[0].workspaces[1].panes[0].surfaces.push({
      ...browser,
      id: "D0000000-0000-4000-8000-0000000000FF",
      ref: "surface:9",
      webviews: [{ pid: 900, title: "second" }],
    });
    browser.webviews.push({ pid: 900, title: "same surface, same pid" });
    const top = m.normalizeTop(reply);
    const keys = [];
    m.walk(top.windows, (n) => keys.push(n.key));
    assert.equal(new Set(keys).size, keys.length, `duplicate keys in ${JSON.stringify(keys)}`);
    // Nodes with ids keep plain, stable keys (saved collapsed state uses them).
    assert.equal(top.windows[0].key, `window:${IDS.win1}`);
    assert.equal(top.windows[0].children[0].key, `workspace:${IDS.wsApi}`);
    // Unique keys survive sorting and a second normalization of the same reply.
    const again = [];
    m.walk(m.normalizeTop(reply).windows, (n) => again.push(n.key));
    assert.deepEqual(again, keys);
  });

  test("unit: task-manager: program totals group unique PIDs by executable", () => {
    const reply = topReply();
    // The same PID reported twice (tag + surface) counts once.
    reply.windows[1].workspaces[0].panes[0].surfaces[0].processes.push({
      pid: 501,
      name: "watcher.exe",
      cpu_percent: 0.5,
      memory_bytes: 20 * MB,
    });
    reply.windows[1].workspaces[0].panes[0].surfaces[0].processes.push({
      pid: 4243,
      name: "SLEEP",
      cpu_percent: 1,
      memory_bytes: 1 * MB,
    });
    const programs = m.programTotals(m.normalizeTop(reply));
    const by = Object.fromEntries(programs.map((p) => [p.key, p]));
    assert.equal(by["program:watcher"].proc, 1);
    assert.equal(by["program:sleep"].proc, 2);
    assert.deepEqual(by["program:sleep"].pids, [4242, 4243]);
    assert.equal(by["program:sleep"].mem, 6 * MB);
    assert.equal(
      programs.reduce((s, p) => s + p.proc, 0),
      7,
      "webview PIDs are not processes",
    );
  });

  test("unit: task-manager: system.memory shapes and aliases", () => {
    const mem = m.normalizeMemory(memoryReply());
    assert.equal(mem.app, 250 * MB);
    assert.equal(mem.child, 705 * MB);
    assert.equal(mem.groups.length, 3);
    assert.equal(mem.groups[1].detail, "api <server>");
    const alt = m.normalizeMemory({
      app_footprint_bytes: 10,
      groups: [{ name: "a", rss_bytes: 3, count: 2, labels: ["x", "y"] }, { memory_bytes: 1 }, null],
    });
    assert.equal(alt.app, 10);
    assert.equal(alt.child, 3);
    assert.deepEqual(
      [alt.groups.length, alt.groups[0].mem, alt.groups[0].proc, alt.groups[0].detail],
      [1, 3, 2, "x, y"],
    );
    assert.deepEqual(m.normalizeMemory({}), { app: null, child: null, groups: [] });
    assert.equal(m.normalizeMemory(null), null);
  });

  test("unit: task-manager: sorting orders siblings at every level and is stable", () => {
    const top = m.normalizeTop(topReply());
    const byMem = m.sortTree(top.windows, "mem", "desc");
    assert.deepEqual(
      byMem.map((w) => w.ref),
      ["window:1", "window:2"],
    );
    const wsAsc = m
      .sortTree(top.windows, "cpu", "asc")
      .find((w) => w.ref === "window:1")
      .children.map((w) => w.title);
    assert.deepEqual(wsAsc, ["docs", "api <server>"]);
    const named = m.sortTree(top.windows, "name", "asc")[0].children.map((w) => w.title);
    assert.deepEqual(named, ["api <server>", "docs"]);
    // Original untouched; unknown key keeps order.
    assert.deepEqual(
      top.windows[0].children.map((w) => w.title),
      ["api <server>", "docs"],
    );
    assert.deepEqual(
      m.sortRows([{ cpu: 1 }, { cpu: 2 }], null, "desc").map((r) => r.cpu),
      [1, 2],
    );
    const ties = m.sortRows(
      [
        { cpu: 1, title: "a" },
        { cpu: 1, title: "b" },
        { cpu: 2, title: "c" },
      ],
      "cpu",
      "desc",
    );
    assert.deepEqual(
      ties.map((r) => r.title),
      ["c", "a", "b"],
    );
    assert.deepEqual(
      m.sortRows([{ title: "item 10" }, { title: "Item 9" }], "name", "asc").map((r) => r.title),
      ["Item 9", "item 10"],
    );
    assert.equal(m.defaultDirection("name"), "asc");
    assert.equal(m.defaultDirection("proc"), "desc");
  });

  test("unit: task-manager: processes sort by the name the row shows", () => {
    const top = m.normalizeTop({
      windows: [
        {
          processes: [
            // Neither the full path nor a title the row does not show decides.
            { pid: 1, name: "C:\\Windows\\System32\\conhost.exe", title: "aa" },
            { pid: 2, name: "bash.exe" },
            { pid: 3, name: "D:\\tools\\awk.exe" },
          ],
        },
      ],
    });
    const procs = m.sortTree(top.windows, "name", "asc")[0].children;
    assert.deepEqual(
      procs.map((p) => p.pid),
      [3, 2, 1],
    );
    assert.equal(m.sortName(procs[2]), "conhost.exe");
  });

  test("unit: task-manager: flatten honors collapsed keys and the Processes toggle", () => {
    const top = m.normalizeTop(topReply());
    const all = m.flatten(top.windows, new Set(), true);
    assert.equal(all[0].node.kind, "window");
    assert.equal(all[0].depth, 0);
    assert.ok(all.some((r) => r.node.pid === 301 && r.depth === 6));
    const noProc = m.flatten(top.windows, new Set(), false);
    assert.equal(noProc.filter((r) => r.node.kind === "process").length, 0);
    const surfaceRow = noProc.find((r) => r.node.kind === "surface" && r.node.type === "terminal");
    assert.equal(surfaceRow.expandable, false);
    assert.ok(noProc.some((r) => r.node.kind === "webview"));
    const collapsed = m.flatten(top.windows, new Set([top.windows[0].key]), true);
    assert.deepEqual(
      collapsed.map((r) => r.node.ref),
      ["window:1", "window:2", "workspace:3", "pane:3", "surface:3", ""],
    );
    assert.equal(collapsed[0].expanded, false);
    assert.equal(collapsed[0].expandable, true);
  });

  test("unit: task-manager: kill targets per row kind", () => {
    const top = m.normalizeTop(topReply());
    const rows = m.flatten(top.windows, new Set(), true).map((r) => r.node);
    const surface = rows.find((n) => n.kind === "surface" && n.type === "terminal");
    assert.deepEqual(m.killPids(surface), [100]);
    assert.deepEqual(m.killPids(rows.find((n) => n.pid === 4242)), [4242]);
    assert.deepEqual(m.killPids(rows.find((n) => n.kind === "tag")), [501]);
    assert.deepEqual(m.killPids(rows.find((n) => n.kind === "webview")), []);
    assert.deepEqual(m.killPids(rows.find((n) => n.kind === "window")), []);
    assert.deepEqual(m.killPids(rows.find((n) => n.kind === "workspace")), [501, 100]);
    assert.deepEqual(m.killPids(rows.find((n) => n.kind === "surface" && n.type === "browser")), []);
    assert.deepEqual(m.killPids(m.codingAgents(top)[0]), [200]);
    assert.deepEqual(m.killPids(null), []);
  });

  test("unit: task-manager: formatting of CPU, memory and time", () => {
    assert.equal(m.formatCpu(0), "0.0%");
    assert.equal(m.formatCpu(99.95), "100.0%");
    assert.equal(m.formatCpu(250.04), "250.0%");
    assert.equal(m.formatCpu(null), "");
    assert.equal(m.formatBytes(0), "0 B");
    assert.equal(m.formatBytes(1023), "1023 B");
    assert.equal(m.formatBytes(1024), "1.0 KB");
    assert.equal(m.formatBytes(12.5 * MB), "12.5 MB");
    assert.equal(m.formatBytes(345 * MB), "345 MB");
    assert.equal(m.formatBytes(1.25 * 1024 * MB), "1.3 GB");
    assert.equal(m.formatBytes(2 ** 70), "1048576 PB");
    assert.equal(m.formatBytes(null), "");
    assert.equal(m.formatTime(new Date(2026, 0, 2, 3, 4, 5)), "03:04:05");
    assert.equal(m.formatTime(new Date(NaN)), "");
    assert.equal(m.formatTime("x"), "");
  });
});
