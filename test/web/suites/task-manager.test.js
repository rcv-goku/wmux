// Smoke: task manager (src/web/task-manager) under its real CSP and Trusted
// Types. Reply shapes follow src/web/task-manager/README.md (system.top,
// system.memory); the main view needs at least one workspace node.
import { run, assertTrue } from "../lib/assert.js";
import { defineSmokeSuite } from "../lib/harness.js";

const PROCESS = { pid: 100, name: "pwsh.exe", cpu_percent: 1.5, memory_bytes: 83886080 };

defineSmokeSuite({
  app: "task-manager",
  kind: "task_manager",
  responses: {
    "panel.set_title": null,
    "panel.state_changed": null,
    "system.top": {
      windows: [
        {
          id: "A0000000-0000-4000-8000-000000000001",
          ref: "window:1",
          key: true,
          workspaces: [
            {
              id: "B0000000-0000-4000-8000-000000000001",
              ref: "workspace:1",
              title: "api",
              selected: true,
              panes: [
                {
                  id: "C0000000-0000-4000-8000-000000000001",
                  ref: "pane:1",
                  focused: true,
                  surfaces: [
                    {
                      id: "D0000000-0000-4000-8000-000000000001",
                      ref: "surface:1",
                      type: "terminal",
                      title: "pwsh",
                      selected: true,
                      processes: [PROCESS],
                    },
                  ],
                },
              ],
            },
          ],
        },
      ],
      totals: { cpu_percent: 1.5, memory_bytes: 83886080, process_count: 1 },
    },
    "system.memory": {
      app: { memory_bytes: 262144000 },
      child: { memory_bytes: 83886080, process_count: 1 },
      groups: [{ command: "pwsh", memory_bytes: 83886080, process_count: 1, workspaces: ["api"] }],
    },
  },
  mainSelector: "#tm-main",
  contentSelector: "#tm-tree tbody",
  contentText: "api",
  errorSelectors: ["#tm-banner"],
  extra(page) {
    assertTrue(page.$("#tm-state").hidden || page.$("#tm-state").closest("[hidden]") !== null, "loading state hidden");
    assertTrue(page.$("#tm-card-cpu").textContent.trim() !== "—", "CPU card filled");
  },
});

run({ suite: "task-manager" });
