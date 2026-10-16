/**
 * Diagram blocks of the markdown preview. ```mermaid fences render as
 * <div class="wmux-diagram wmux-mermaid"> holding the source in a hidden
 * <pre class="wmux-source"> and an empty .wmux-diagram-output. This module
 * loads mermaid lazily (at most once per page, only when such a block exists)
 * and fills the output with the SVG, or with an inline error box naming the
 * library and the message when the diagram does not parse.
 *
 * CSP: the panel allows no inline styles. Mermaid's SVG carries a <style>
 * element and style="" attributes, which the browser would ignore; both are
 * re-applied through the CSSOM (a constructed stylesheet and element.style),
 * which the CSP does not restrict.
 */
import { t } from "./strings.js";

/** Vendored mermaid build (IIFE that defines the global `mermaid`). */
export const MERMAID_SRC = "../_vendor/mermaid@11.17.2/mermaid.min.js";

/** Longest diagram source handed to mermaid. */
export const MAX_DIAGRAM_SOURCE = 50000;

const scriptLoads = new Map();

/**
 * Load a classic script once per document and resolve with `globalThis[name]`.
 * @param {Document} doc
 * @param {string} src same-origin URL
 * @param {string} globalName
 */
export function loadScriptOnce(doc, src, globalName) {
  const view = doc.defaultView || globalThis;
  if (view[globalName]) return Promise.resolve(view[globalName]);
  const key = src + "|" + globalName;
  if (scriptLoads.has(key)) return scriptLoads.get(key);
  const promise = new Promise((resolve, reject) => {
    const script = doc.createElement("script");
    script.src = src;
    script.async = true;
    script.addEventListener("load", () => {
      if (view[globalName]) resolve(view[globalName]);
      else reject(new Error(globalName + " did not load"));
    });
    script.addEventListener("error", () => reject(new Error("Failed to load " + src)));
    doc.head.appendChild(script);
  });
  scriptLoads.set(key, promise);
  promise.catch(() => scriptLoads.delete(key));
  return promise;
}

/**
 * @param {{document: Document, purify: object, loadMermaid?: () => Promise<object>,
 *          scheme?: () => "dark"|"light"}} deps
 */
export function createDiagrams(deps) {
  const doc = deps.document;
  const purify = deps.purify;
  const loadMermaid = deps.loadMermaid || (() => loadScriptOnce(doc, MERMAID_SRC, "mermaid"));
  const scheme = deps.scheme || (() => "dark");
  let counter = 0;
  let initializedTheme = null;
  let adoptedSheets = [];

  function errorBox(library, message) {
    const box = doc.createElement("div");
    box.className = "wmux-diagram-error";
    box.setAttribute("role", "alert");
    box.textContent = t("markdown.diagram.error", { library, message });
    return box;
  }

  /** Move <style> text into a constructed stylesheet and style="" into element.style. */
  function applySvgStyles(container) {
    const view = doc.defaultView;
    for (const style of Array.from(container.querySelectorAll("style"))) {
      const css = style.textContent || "";
      style.remove();
      if (view && typeof view.CSSStyleSheet === "function" && "adoptedStyleSheets" in doc) {
        try {
          const sheet = new view.CSSStyleSheet();
          sheet.replaceSync(css);
          adoptedSheets.push(sheet);
          doc.adoptedStyleSheets = [...doc.adoptedStyleSheets, sheet];
        } catch {
          // Unsupported or invalid CSS: the diagram stays unstyled.
        }
      }
    }
    for (const el of Array.from(container.querySelectorAll("[style]"))) {
      const css = el.getAttribute("style");
      el.removeAttribute("style");
      if (el.style) el.style.cssText = css;
    }
  }

  /** Drop the stylesheets added for previous renders (called before a re-render). */
  function reset() {
    if (adoptedSheets.length && "adoptedStyleSheets" in doc) {
      const old = new Set(adoptedSheets);
      doc.adoptedStyleSheets = doc.adoptedStyleSheets.filter((sheet) => !old.has(sheet));
    }
    adoptedSheets = [];
  }

  async function renderOne(mermaid, block) {
    const source = block.querySelector(".wmux-source");
    const output = block.querySelector(".wmux-diagram-output");
    if (!source || !output) return;
    const text = source.textContent || "";
    if (text.length > MAX_DIAGRAM_SOURCE) {
      output.replaceChildren(errorBox("Mermaid", "diagram source is too large"));
      block.setAttribute("data-state", "error");
      return;
    }
    counter += 1;
    const id = "wmux-mermaid-" + counter;
    try {
      const result = await mermaid.render(id, text);
      const svg = typeof result === "string" ? result : result && result.svg;
      if (typeof svg !== "string") throw new Error("no SVG produced");
      const fragment = purify.sanitize(svg, {
        USE_PROFILES: { svg: true, svgFilters: true, html: true },
        ADD_TAGS: ["foreignObject", "style"],
        RETURN_DOM_FRAGMENT: true,
      });
      output.replaceChildren(fragment);
      applySvgStyles(output);
      block.setAttribute("data-state", "rendered");
    } catch (err) {
      const message = err && err.message ? String(err.message) : String(err);
      output.replaceChildren(errorBox("Mermaid", message.split("\n")[0].slice(0, 500)));
      block.setAttribute("data-state", "error");
    } finally {
      // Mermaid leaves its scratch elements (children of <body>) behind when parsing fails.
      for (const leftover of [doc.getElementById(id), doc.getElementById("d" + id)]) {
        if (leftover && leftover.parentNode === doc.body) leftover.remove();
      }
    }
  }

  /**
   * Render every unrendered diagram block under root.
   * @returns {Promise<number>} number of blocks processed
   */
  async function render(root) {
    const blocks = Array.from(root.querySelectorAll(".wmux-mermaid:not([data-state])"));
    if (!blocks.length) return 0;
    for (const block of blocks) {
      block.setAttribute("data-state", "loading");
      const output = block.querySelector(".wmux-diagram-output");
      if (output) output.textContent = t("markdown.diagram.loading");
    }
    let mermaid;
    try {
      mermaid = await loadMermaid();
    } catch (err) {
      for (const block of blocks) {
        const output = block.querySelector(".wmux-diagram-output");
        if (output) output.replaceChildren(errorBox("Mermaid", String((err && err.message) || err)));
        block.setAttribute("data-state", "error");
      }
      return blocks.length;
    }
    const theme = scheme() === "light" ? "default" : "dark";
    if (initializedTheme !== theme) {
      mermaid.initialize({
        startOnLoad: false,
        securityLevel: "strict",
        theme,
        suppressErrorRendering: true,
      });
      initializedTheme = theme;
    }
    for (const block of blocks) {
      if (!block.isConnected) continue;
      await renderOne(mermaid, block);
    }
    return blocks.length;
  }

  return { render, reset };
}
