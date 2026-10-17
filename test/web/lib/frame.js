// Blank page for test/web suites that need a fresh realm (a new wmux-bridge.js
// singleton). The suite installs the mock host on this frame's Window before it
// loads, then imports modules here through window.__wmuxFrameImport(url).
"use strict";
window.__wmuxFrameImport = (url) => import(url);
