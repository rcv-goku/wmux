/**
 * Diff panel entry module (index.html). Loads the vendored libraries, starts
 * theme sync and the app. All logic lives in app.js and its helpers.
 */
import hljs from "../_vendor/highlightjs-cdn-assets@11.12.0/highlight.min.js";
import DOMPurify from "../_vendor/dompurify@3.4.17/purify.es.js";
import "../_shared/theme.js";
import { createApp } from "./app.js";

function start() {
  const app = createApp({ document, libs: { hljs, purify: DOMPurify } });
  app.start().catch((err) => console.error("[diff] start failed", err));
}

if (typeof document !== "undefined") {
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start, { once: true });
  } else {
    start();
  }
}
