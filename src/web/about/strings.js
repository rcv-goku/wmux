/**
 * About panel strings. Keys are stable ids for translators (W7); values are the
 * English defaults handed to tr(). index.html carries the same keys in
 * data-i18n attributes for its static text.
 */
import { tr } from "../_shared/strings.js";

export const STRINGS = Object.freeze({
  "about.title": "About wmux",
  "about.product": "wmux",
  "about.tagline": "A terminal multiplexer for Windows, built on Ghostty.",
  "about.version": "Version {version}",
  "about.versionUnknown": "Version unknown",
  "about.loading": "Loading build information…",

  "about.build.heading": "Build information",
  "about.build.version": "Version",
  "about.build.channel": "Channel",
  "about.build.commit": "Commit",
  "about.build.build_mode": "Build mode",
  "about.build.zig_version": "Zig",
  "about.build.app_runtime": "App runtime",
  "about.build.renderer": "Renderer",
  "about.build.font_engine": "Font engine",
  "about.build.webview2_runtime": "WebView2 runtime",
  "about.build.os": "Windows",
  "about.build.arch": "Architecture",
  "about.build.build": "Build",
  "about.build.platform": "Platform",
  "about.copy": "Copy version info",
  "about.copied": "Version information copied to the clipboard.",
  "about.copyFailed": "Could not copy the version information: {message}",

  "about.license.heading": "License",
  "about.license.summary": "wmux is free software, released under the {license}.",
  "about.license.defaultName": "MIT License",
  "about.license.show": "Show license",
  "about.license.hide": "Hide license",
  "about.notices.show": "Third-party notices",
  "about.notices.hide": "Hide third-party notices",
  "about.notices.loading": "Loading third-party notices…",
  "about.notices.unavailable": "Third-party notices are not available in this build.",
  "about.homepage": "Project website",
  "about.openFailed": "Could not open the link: {message}",

  "about.status.offline": "Not running inside wmux: showing placeholder information.",
  "about.status.error": "Could not load the build information: {message}",
});

/**
 * Translate an About panel string.
 * @param {keyof typeof STRINGS | string} key
 * @param {Record<string, unknown>} [params]
 */
export function t(key, params) {
  const fallback = Object.prototype.hasOwnProperty.call(STRINGS, key) ? STRINGS[key] : key;
  return tr(key, fallback, params);
}
