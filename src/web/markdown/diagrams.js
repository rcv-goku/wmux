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
 * which the CSP does not restrict. While mermaid lays a diagram out, its
 * <style> is blocked as well, so text would be measured in the page font and
 * drawn in the diagram font (clipped labels). Mermaid therefore renders into
 * an off-screen container that carries the diagram font through the CSSOM.
 */
import { t } from "./strings.js";

/** Vendored mermaid build (IIFE that defines the global `mermaid`). */
export const MERMAID_SRC = "../_vendor/mermaid@11.17.2/mermaid.min.js";

/** Longest diagram source handed to mermaid. */
export const MAX_DIAGRAM_SOURCE = 50000;

/**
 * Font diagrams are drawn and measured in: mermaid's theme default, passed to
 * mermaid explicitly so its CSS and the measuring container cannot drift apart.
 */
export const DIAGRAM_FONT_FAMILY = '"trebuchet ms", verdana, arial, sans-serif';
export const DIAGRAM_FONT_SIZE = "16px";

const scriptLoads = new Map();

/**
 * Whether a value is the mermaid API. window.mermaid can also be an element
 * of the rendered document with id or name "mermaid" (named access).
 */
export function isMermaidApi(value) {
  return Boolean(value) && typeof value.render === "function" && typeof value.initialize === "function";
}

/**
 * Load a classic script once per document and resolve with `globalThis[name]`.
 * @param {Document} doc
 * @param {string} src same-origin URL
 * @param {string} globalName
 * @param {(value: unknown) => boolean} [isLoaded] whether the global is the
 *   library (default: truthy). Pass a real check where documents can define
 *   elements named like the global.
 */
export function loadScriptOnce(doc, src, globalName, isLoaded) {
  const view = doc.defaultView || globalThis;
  const loaded = isLoaded || Boolean;
  if (loaded(view[globalName])) return Promise.resolve(view[globalName]);
  const key = src + "|" + globalName;
  if (scriptLoads.has(key)) return scriptLoads.get(key);
  const promise = new Promise((resolve, reject) => {
    const script = doc.createElement("script");
    script.src = src;
    script.async = true;
    script.addEventListener("load", () => {
      if (loaded(view[globalName])) resolve(view[globalName]);
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
  const loadMermaid = deps.loadMermaid || (() => loadScriptOnce(doc, MERMAID_SRC, "mermaid", isMermaidApi));
  const scheme = deps.scheme || (() => "dark");
  let counter = 0;
  let initializedTheme = null;
  let adoptedSheets = [];
  let scratch = null;

  function errorBox(library, message) {
    const box = doc.createElement("div");
    box.className = "wmux-diagram-error";
    box.setAttribute("role", "alert");
    box.textContent = t("markdown.diagram.error", { library, message });
    return box;
  }

  function failAll(blocks, err) {
    const message = String((err && err.message) || err);
    for (const block of blocks) {
      const output = block.querySelector(".wmux-diagram-output");
      if (output) output.replaceChildren(errorBox("Mermaid", message));
      block.setAttribute("data-state", "error");
    }
  }

  /** Laid-out but invisible element that mermaid renders and measures text in. */
  function scratchContainer() {
    if (scratch && scratch.isConnected) return scratch;
    scratch = doc.createElement("div");
    scratch.className = "mdv-diagram-scratch";
    scratch.setAttribute("aria-hidden", "true");
    for (const [name, value] of [
      ["position", "absolute"],
      ["left", "-10000px"],
      ["top", "0"],
      ["visibility", "hidden"],
      ["font-family", DIAGRAM_FONT_FAMILY],
      ["font-size", DIAGRAM_FONT_SIZE],
    ]) {
      scratch.style.setProperty(name, value);
    }
    doc.body.append(scratch);
    return scratch;
  }

  /** Remove what mermaid left behind for one render (it does when parsing fails). */
  function removeLeftovers(id, container) {
    const ids = new Set([id, "d" + id, "i" + id]);
    for (const parent of [container, doc.body]) {
      for (const el of Array.from(parent.children)) {
        if (ids.has(el.id)) el.remove();
      }
    }
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
    const container = scratchContainer();
    try {
      const result = await mermaid.render(id, text, container);
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
      removeLeftovers(id, container);
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
      failAll(blocks, err);
      return blocks.length;
    }
    const theme = scheme() === "light" ? "default" : "dark";
    if (initializedTheme !== theme) {
      try {
        mermaid.initialize({
          startOnLoad: false,
          securityLevel: "strict",
          theme,
          suppressErrorRendering: true,
          fontFamily: DIAGRAM_FONT_FAMILY,
          themeVariables: { fontFamily: DIAGRAM_FONT_FAMILY, fontSize: DIAGRAM_FONT_SIZE },
        });
      } catch (err) {
        failAll(blocks, err);
        return blocks.length;
      }
      initializedTheme = theme;
    }
    for (const block of blocks) {
      if (!block.isConnected) continue;
      await renderOne(mermaid, block);
    }
    return blocks.length;
  }

  /** reset() plus removing the measuring container (the panel is going away). */
  function dispose() {
    reset();
    if (scratch) scratch.remove();
    scratch = null;
  }

  return { render, reset, dispose };
}
