// Smoke: settings panel (src/web/settings) under its real CSP and Trusted
// Types. The schema reply is a minimal INFERRED shape (README documents
// {schema, docs_url?} with a JSON Schema whose rows come from "properties").
import { run, assertTrue } from "../lib/assert.js";
import { defineSmokeSuite } from "../lib/harness.js";

defineSmokeSuite({
  app: "settings",
  responses: {
    "panel.set_title": null,
    "panel.state_changed": null,
    "wmux.settings.schema": {
      schema: {
        properties: {
          app: {
            type: "object",
            properties: {
              confirmQuit: {
                title: "Confirm quit",
                description: "Ask before quitting.",
                type: "boolean",
                default: true,
                "x-wmux-section": "app",
              },
            },
          },
        },
      },
    },
    "wmux.settings.get_effective": {
      values: { "app.confirmQuit": { value: true, source: "default" } },
      files: { wmux: "C:\\Users\\me\\.config\\wmux\\wmux.json" },
    },
  },
  mainSelector: "#set-content",
  contentSelector: '#set-content .set-row[data-path="app.confirmQuit"]',
  contentText: "Confirm quit",
  errorSelectors: [".set-load-error", '#set-status[data-kind="error"]', ".set-row-error"],
  extra(page) {
    assertTrue(page.$("#set-nav-list .set-nav-item") !== null, "section navigation rendered");
  },
});

run({ suite: "settings" });
