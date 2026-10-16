/**
 * Plan text renderer: markdown-it (raw HTML off) then DOMPurify, returning a
 * sanitized DocumentFragment. Plans come from agents and are untrusted.
 * Images, forms, media and styles are removed; links keep only http(s) and
 * mailto targets and are routed by app.js (never navigated in the page).
 */

/** Plans longer than this render as plain text (cheap and bounded). */
export const MAX_MARKDOWN_CHARS = 200000;

const PURIFY_CONFIG = {
  RETURN_DOM_FRAGMENT: true,
  FORBID_TAGS: ["img", "style", "form", "input", "button", "textarea", "select", "iframe", "object", "embed", "video", "audio", "picture", "source", "svg", "math", "link", "meta", "base", "template"],
  FORBID_ATTR: ["style", "srcset", "target", "ping", "id", "class"],
  ALLOWED_URI_REGEXP: /^(?:https?:|mailto:)/i,
};

/**
 * @param {{markdownit: Function, purify: object, document: Document}} libs
 * @returns {(text: string) => DocumentFragment|null}
 */
export function createMarkdownRenderer(libs) {
  if (!libs || typeof libs.markdownit !== "function" || !libs.purify || typeof libs.purify.sanitize !== "function") {
    return () => null;
  }
  const md = libs.markdownit({ html: false, linkify: true, breaks: false, typographer: false });
  return function renderMarkdown(text) {
    if (typeof text !== "string" || text === "" || text.length > MAX_MARKDOWN_CHARS) return null;
    let html;
    try {
      html = md.render(text);
    } catch {
      return null;
    }
    const fragment = libs.purify.sanitize(html, PURIFY_CONFIG);
    if (!fragment || typeof fragment.querySelectorAll !== "function") return null;
    for (const a of fragment.querySelectorAll("a")) a.setAttribute("rel", "noreferrer noopener");
    return fragment;
  };
}
