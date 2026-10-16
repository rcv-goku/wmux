/**
 * Markdown -> sanitized DOM for the markdown panel.
 *
 *   const renderer = createRenderer({ markdownit, footnote, hljs, purify, document });
 *   const out = renderer.render(sourceText, { baseUrl, approvedImages });
 *   container.replaceChildren(out.fragment);
 *
 * Pipeline: leading YAML frontmatter is split off; markdown-it renders the body
 * (GFM tables, strikethrough, autolinks, task lists, footnotes) with
 * highlight.js for fenced code and GitHub-style heading ids; DOMPurify
 * sanitizes the HTML (raw HTML in markdown is allowed but scripts, styles,
 * forms, frames and embeds are dropped); the result is then post-processed in
 * the DOM: copy buttons on code blocks, images routed through the panel's file
 * host or replaced by a "Remote image blocked" placeholder, task checkboxes
 * disabled, link targets removed (clicks are routed by the app), and inline
 * code spans that look like markdown paths marked for an existence check.
 */
import { classifyImage, looksLikeMarkdownPath } from "./links.js";
import { t } from "./strings.js";

/** Code blocks longer than this are not syntax highlighted. */
export const MAX_HIGHLIGHT_CHARS = 200000;

/** Diagram languages rendered by a lazily loaded library. */
export const DIAGRAM_LANGUAGES = Object.freeze(["mermaid"]);

const FRONTMATTER_RE = /^---[ \t]*\r?\n(?:([\s\S]*?)\r?\n)?(?:---|\.\.\.)[ \t]*(?:\r?\n|$)/;

const FORBID_TAGS = [
  "style",
  "form",
  "button",
  "select",
  "option",
  "textarea",
  "meta",
  "base",
  "link",
  "iframe",
  "frame",
  "frameset",
  "object",
  "embed",
  "applet",
  "template",
  "dialog",
  "portal",
  "noscript",
];
const FORBID_ATTR = ["style", "srcset", "formaction", "ping", "autofocus", "target", "background"];
// Any scheme except script and data URLs (data: images are allowed separately
// by DOMPurify's DATA_URI_TAGS). Routing decides what a click does.
const ALLOWED_URI_REGEXP = /^(?!(?:javascript|vbscript|data):)/i;

/**
 * GitHub-style heading slug: lowercase, characters other than letters, marks,
 * digits, connector punctuation, spaces and hyphens removed, spaces -> "-".
 */
export function slugify(text) {
  return String(text)
    .trim()
    .toLowerCase()
    .replace(/[^\p{L}\p{M}\p{N}\p{Pc}\- ]/gu, "")
    .replace(/ /g, "-");
}

/** Unique slugs per document: "a", "a-1", "a-2", ... */
export function createSlugger() {
  // occurrences: slug -> how many suffixed variants of it were handed out
  const occurrences = new Map();
  return (text) => {
    const base = slugify(text);
    if (base === "") return "";
    let slug = base;
    while (occurrences.has(slug)) {
      const n = occurrences.get(base) + 1;
      occurrences.set(base, n);
      slug = base + "-" + n;
    }
    occurrences.set(slug, 0);
    return slug;
  };
}

/**
 * Split leading YAML frontmatter ("---\n...\n---") from the body.
 * @returns {{frontmatter: string|null, body: string}}
 */
export function extractFrontmatter(source) {
  const text = typeof source === "string" ? source.replace(/^﻿/, "") : "";
  const match = FRONTMATTER_RE.exec(text);
  if (!match) return { frontmatter: null, body: text };
  return { frontmatter: match[1] || "", body: text.slice(match[0].length) };
}

function inlineText(token) {
  let out = "";
  for (const child of token.children || []) {
    if (child.type === "text" || child.type === "code_inline" || child.type === "text_special") {
      out += child.content;
    } else if (child.type === "image") {
      out += inlineText(child);
    }
  }
  return out;
}

/**
 * markdown-it plugin: table column alignment as the align attribute (the
 * default style="text-align:…" is dropped by the sanitizer and the CSP).
 */
function tableAlign(md) {
  md.core.ruler.push("wmux_table_align", (state) => {
    for (const token of state.tokens) {
      if (token.type !== "th_open" && token.type !== "td_open") continue;
      const style = token.attrGet("style");
      if (!style) continue;
      const match = /text-align:\s*(left|right|center)/.exec(style);
      token.attrs = token.attrs.filter((attr) => attr[0] !== "style");
      if (match) token.attrSet("align", match[1]);
    }
  });
}

/** markdown-it plugin: GitHub heading ids. */
function headingIds(md) {
  md.core.ruler.push("wmux_heading_ids", (state) => {
    const slug = state.env.slugger || (state.env.slugger = createSlugger());
    const tokens = state.tokens;
    for (let i = 0; i < tokens.length - 1; i += 1) {
      if (tokens[i].type !== "heading_open") continue;
      const id = slug(inlineText(tokens[i + 1]));
      if (id !== "") tokens[i].attrSet("id", id);
    }
  });
}

const TASK_RE = /^\[([ xX])\](?=[ \t]|$)/;

/** markdown-it plugin: GFM task list items ("- [ ] todo", "- [x] done"). */
function taskLists(md) {
  md.core.ruler.after("inline", "wmux_task_lists", (state) => {
    const tokens = state.tokens;
    for (let i = 2; i < tokens.length; i += 1) {
      const inline = tokens[i];
      if (
        inline.type !== "inline" ||
        tokens[i - 1].type !== "paragraph_open" ||
        tokens[i - 2].type !== "list_item_open"
      ) {
        continue;
      }
      const first = inline.children && inline.children[0];
      if (!first || first.type !== "text") continue;
      const match = TASK_RE.exec(first.content);
      if (!match) continue;

      first.content = first.content.slice(match[0].length);
      const box = new state.Token("html_inline", "", 0);
      box.content =
        '<input type="checkbox" class="task-list-item-checkbox" disabled' +
        (match[1] === " " ? "" : " checked") +
        ">";
      inline.children.unshift(box);

      const item = tokens[i - 2];
      item.attrJoin("class", "task-list-item");
      for (let j = i - 3; j >= 0; j -= 1) {
        const tok = tokens[j];
        if (
          (tok.type === "bullet_list_open" || tok.type === "ordered_list_open") &&
          tok.level === item.level - 1
        ) {
          if (!(tok.attrGet("class") || "").includes("contains-task-list")) {
            tok.attrJoin("class", "contains-task-list");
          }
          break;
        }
      }
    }
  });
}

/**
 * @param {{markdownit: Function, footnote?: Function, hljs?: object, purify: object,
 *          document: Document}} libs
 */
export function createRenderer(libs) {
  if (!libs || typeof libs.markdownit !== "function") throw new TypeError("markdownit required");
  if (!libs.purify || typeof libs.purify.sanitize !== "function") {
    throw new TypeError("DOMPurify required");
  }
  const doc = libs.document;
  const hljs = libs.hljs || null;
  const purify = libs.purify;

  function highlight(code, lang) {
    const name = String(lang || "").toLowerCase();
    if (!hljs || name === "" || code.length > MAX_HIGHLIGHT_CHARS || !hljs.getLanguage(name)) {
      return "";
    }
    try {
      return hljs.highlight(code, { language: name, ignoreIllegals: true }).value;
    } catch {
      return "";
    }
  }

  const md = libs.markdownit({ html: true, linkify: true, typographer: false, highlight });
  const escapeHtml = md.utils.escapeHtml;
  md.validateLink = (url) => {
    const value = String(url).trim().toLowerCase();
    if (/^(?:javascript|vbscript):/.test(value)) return false;
    if (value.startsWith("data:")) return /^data:image\/(?:gif|png|jpeg|webp);/.test(value);
    return true;
  };
  if (typeof libs.footnote === "function") md.use(libs.footnote);
  md.use(headingIds);
  md.use(taskLists);
  md.use(tableAlign);

  const defaultFence = md.renderer.rules.fence;
  md.renderer.rules.fence = (tokens, idx, options, env, self) => {
    const token = tokens[idx];
    const info = token.info ? md.utils.unescapeAll(token.info).trim() : "";
    const lang = info.split(/\s+/)[0].toLowerCase();
    if (DIAGRAM_LANGUAGES.includes(lang)) {
      env.diagrams = (env.diagrams || 0) + 1;
      return (
        '<div class="wmux-diagram wmux-' +
        lang +
        '" data-diagram="' +
        lang +
        '"><pre class="wmux-source" hidden>' +
        escapeHtml(token.content) +
        '</pre><div class="wmux-diagram-output"></div></div>\n'
      );
    }
    return defaultFence(tokens, idx, options, env, self);
  };

  function frontmatterHtml(yaml) {
    const body = highlight(yaml, "yaml") || escapeHtml(yaml);
    return (
      '<details class="wmux-frontmatter"><summary>' +
      escapeHtml(t("markdown.frontmatter")) +
      '</summary><pre><code class="hljs language-yaml">' +
      body +
      "</code></pre></details>\n"
    );
  }

  /** Markdown source -> HTML string (unsanitized; exported for diagnostics and tests). */
  function toHtml(source) {
    const { frontmatter, body } = extractFrontmatter(source);
    const env = {};
    let html = md.render(body, env);
    if (frontmatter !== null) html = frontmatterHtml(frontmatter) + html;
    return { html, frontmatter, diagrams: env.diagrams || 0 };
  }

  function sanitize(html) {
    return purify.sanitize(html, {
      RETURN_DOM_FRAGMENT: true,
      FORBID_TAGS,
      FORBID_ATTR,
      ALLOWED_URI_REGEXP,
    });
  }

  /**
   * Render markdown to a sanitized, post-processed DocumentFragment.
   * @param {string} source
   * @param {{baseUrl?: string|null, approvedImages?: Set<string>}} [options]
   */
  function render(source, options) {
    const opts = options || {};
    const { html, frontmatter, diagrams } = toHtml(typeof source === "string" ? source : "");
    const fragment = sanitize(html);
    const imageRequests = [];
    enhance(fragment, opts, imageRequests);
    return { fragment, frontmatter, diagrams, imageRequests };
  }

  function enhance(root, opts, imageRequests) {
    const approved = opts.approvedImages || new Set();

    // data-mdv-* attributes are the app's own markers; documents cannot set them.
    for (const el of Array.from(root.querySelectorAll("*"))) {
      for (const name of el.getAttributeNames()) {
        if (name.startsWith("data-mdv-")) el.removeAttribute(name);
      }
    }

    for (const input of Array.from(root.querySelectorAll("input"))) {
      if (String(input.getAttribute("type")).toLowerCase() !== "checkbox") input.remove();
      else input.setAttribute("disabled", "");
    }

    for (const a of Array.from(root.querySelectorAll("a"))) {
      a.removeAttribute("target");
      if (a.hasAttribute("href")) a.setAttribute("rel", "noreferrer noopener");
    }

    for (const code of Array.from(root.querySelectorAll("pre > code"))) {
      const pre = code.parentElement;
      if (pre.closest(".wmux-diagram, .wmux-frontmatter")) continue;
      code.classList.add("hljs");
      const block = doc.createElement("div");
      block.className = "mdv-code-block";
      pre.replaceWith(block);
      const button = doc.createElement("button");
      button.type = "button";
      button.className = "mdv-copy-code";
      button.textContent = t("markdown.copyCode");
      button.setAttribute("aria-label", t("markdown.copyCode"));
      block.append(button, pre);
    }

    for (const img of Array.from(root.querySelectorAll("img"))) {
      const target = classifyImage(img.getAttribute("src"), opts.baseUrl || null);
      img.setAttribute("loading", "lazy");
      img.setAttribute("referrerpolicy", "no-referrer");
      switch (target.kind) {
        case "data":
        case "host":
          break;
        case "local":
          img.setAttribute("src", target.url);
          break;
        case "absolute":
          img.removeAttribute("src");
          img.setAttribute("data-mdv-local-src", target.path);
          imageRequests.push({ img, path: target.path });
          break;
        case "remote":
          if (approved.has(target.url)) {
            img.setAttribute("src", target.url);
          } else {
            blockRemoteImage(img, target.url);
          }
          break;
        default:
          img.removeAttribute("src");
      }
    }

    for (const code of Array.from(root.querySelectorAll("code"))) {
      if (code.closest("pre, a")) continue;
      if (looksLikeMarkdownPath(code.textContent)) {
        code.setAttribute("data-mdv-path", code.textContent.trim());
      }
    }
  }

  /** Replace a remote image with the consent placeholder (after its link, if any). */
  function blockRemoteImage(img, url) {
    const placeholder = remoteImagePlaceholder(url, img.getAttribute("alt") || "");
    const link = img.closest("a");
    if (link) {
      img.remove();
      if (link.textContent.trim() === "" && !link.querySelector("img")) {
        link.textContent = img.getAttribute("alt") || url;
      }
      link.after(placeholder);
    } else {
      img.replaceWith(placeholder);
    }
  }

  function remoteImagePlaceholder(url, alt) {
    const box = doc.createElement("span");
    box.className = "wmux-remote-image";
    box.setAttribute("data-url", url);
    if (alt) box.setAttribute("data-alt", alt);
    box.setAttribute("role", "group");
    box.setAttribute("aria-label", t("markdown.image.blocked"));

    const title = doc.createElement("strong");
    title.className = "wmux-remote-image-title";
    title.textContent = t("markdown.image.blocked");
    const body = doc.createElement("span");
    body.className = "wmux-remote-image-body";
    body.textContent = t("markdown.image.blockedBody");
    const code = doc.createElement("code");
    code.className = "wmux-remote-image-url";
    code.textContent = url;
    const actions = doc.createElement("span");
    actions.className = "wmux-remote-image-actions";
    for (const [action, key] of [
      ["load", "markdown.image.load"],
      ["open", "markdown.image.open"],
      ["copy", "markdown.image.copy"],
    ]) {
      const button = doc.createElement("button");
      button.type = "button";
      button.setAttribute("data-image-action", action);
      button.textContent = t(key);
      actions.append(button);
    }
    box.append(title, body, code, actions);
    return box;
  }

  return { render, toHtml, sanitize, highlight, md };
}
