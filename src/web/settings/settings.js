/**
 * Settings panel entry module (index.html). Starts theme sync and the app.
 * All logic lives in app.js and its helpers.
 */
import "../_shared/theme.js";
import { createApp } from "./app.js";

function start() {
  const app = createApp({ document });
  app.start().catch((err) => console.error("[settings] start failed", err));
}

if (typeof document !== "undefined") {
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start, { once: true });
  } else {
    start();
  }
}
