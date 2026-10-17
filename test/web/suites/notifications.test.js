// Smoke: notifications panel (src/web/notifications) under its real CSP and
// Trusted Types. Reply shapes follow src/web/notifications/README.md.
import { run, assertTrue } from "../lib/assert.js";
import { defineSmokeSuite } from "../lib/harness.js";

const WS = "11111111-1111-4111-8111-111111111111";

defineSmokeSuite({
  app: "notifications",
  init: { keymap: { jumpToUnread: ["ctrl+shift+u"] } },
  responses: {
    "panel.set_title": null,
    "panel.subscribe": null,
    "panel.state_changed": null,
    "notification.list": {
      notifications: [
        {
          id: "00000000-0000-4000-8000-000000000001",
          workspace: WS,
          surface: "AAAAAAAA-0000-4000-8000-000000000001",
          title: "Title 1",
          subtitle: "",
          body: "Body 1",
          created_at_ms: 1792164600000,
          read: false,
        },
      ],
      marker_count: 0,
    },
    "workspace.list": { workspaces: [{ id: WS, title: "api" }] },
  },
  mainSelector: "#ntf-list",
  contentSelector: "#ntf-list .ntf-row",
  contentText: "Title 1",
  errorSelectors: ["#ntf-status"],
  extra(page) {
    assertTrue(page.$("#ntf-empty").hidden, "empty state hidden");
  },
});

run({ suite: "notifications" });
