// Smoke: feed panel (src/web/feed) under its real CSP. Reply shapes follow
// src/web/feed/README.md; the default Actionable tab lists pending decisions.
import { run, assertTrue } from "../lib/assert.js";
import { defineSmokeSuite } from "../lib/harness.js";

defineSmokeSuite({
  app: "feed",
  responses: {
    "panel.set_title": null,
    "panel.subscribe": null,
    "panel.state_changed": null,
    "feed.list": {
      items: [
        {
          id: "00000000-0000-4000-8000-000000000001",
          kind: "permissionRequest",
          status: "pending",
          source: "claude",
          hook_event_name: "PermissionRequest",
          title: "Item 1",
          detail: "rm -rf build",
          created_at: 1792164540,
          request_id: "req-1",
          session_id: "sess-1",
          workspace_id: "11111111-1111-4111-8111-111111111111",
          surface_id: "AAAAAAAA-0000-4000-8000-000000000001",
          tool_name: "Bash",
          options: ["once", "always", "all", "bypass", "deny"],
        },
      ],
      has_more: false,
    },
  },
  mainSelector: "#feed-list",
  contentSelector: "#feed-list .feed-card",
  contentText: "Item 1",
  errorSelectors: ["#feed-status"],
  extra(page) {
    assertTrue(page.$("#feed-empty").hidden, "empty state hidden");
  },
});

run({ suite: "feed" });
