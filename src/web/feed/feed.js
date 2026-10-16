/**
 * Feed panel entry module (index.html). Loads the vendored markdown-it and
 * DOMPurify for plan text, starts theme sync and the app. All logic lives in
 * app.js and its helpers.
 */
import markdownit from "../_vendor/markdown-it@15.0.2/markdown-it.js";
import DOMPurify from "../_vendor/dompurify@3.4.17/purify.es.js";
import "../_shared/theme.js";
import { createApp } from "./app.js";
import { createMarkdownRenderer } from "./render.js";

function start() {
  const renderMarkdown = createMarkdownRenderer({ markdownit, purify: DOMPurify, document });
  const app = createApp({ document, renderMarkdown });
  app.start().catch((err) => console.error("[feed] start failed", err));
}

if (typeof document !== "undefined") {
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start, { once: true });
  } else {
    start();
  }
}
