// Smoke: todo panel (src/web/todo) under its real CSP and Trusted Types.
// Reply shapes follow src/web/todo/README.md (workspace.todo.list).
import { run, assertTrue } from "../lib/assert.js";
import { defineSmokeSuite } from "../lib/harness.js";

defineSmokeSuite({
  app: "todo",
  init: { params: { workspace_id: "8F0C3C1E-0000-4000-8000-00000000000A", focus_add: false } },
  responses: {
    "panel.set_title": null,
    "panel.subscribe": null,
    "panel.state_changed": null,
    "workspace.todo.list": {
      items: [
        { id: "id-1", text: "write test", state: "pending", origin: "user" },
        { id: "id-2", text: "lint", state: "completed", origin: "agent" },
      ],
      completed: 1,
      total: 2,
    },
    "workspace.status.get": { lane: "todo", pinned: false },
  },
  mainSelector: "#todo-list",
  contentSelector: "#todo-list .todo-item .todo-text",
  contentText: "write test",
  errorSelectors: ["#todo-error", "#todo-unavailable"],
  extra(page) {
    assertTrue(page.$$("#todo-list .todo-item").length === 2, "two items");
  },
});

run({ suite: "todo" });
