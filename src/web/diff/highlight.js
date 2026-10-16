/**
 * Syntax highlighting and character-range marking for diff lines.
 *
 * highlight.js output is sanitized with DOMPurify (only `<span class>`
 * survives) into a DOM fragment, which is then split into one fragment per
 * line; no HTML string from the patch ever reaches innerHTML. Word-diff and
 * find highlights are added afterwards by wrapping text-node ranges.
 */

/** Hunk sides longer than this (characters) are not syntax highlighted. */
export const MAX_HIGHLIGHT_CHARS = 100000;

const NAME_LANGUAGES = {
  makefile: "makefile",
  gnumakefile: "makefile",
  dockerfile: "dockerfile",
  "cmakelists.txt": "cmake",
  "build.zig": "zig",
  "build.zig.zon": "zig",
  ".gitignore": "bash",
  ".bashrc": "bash",
  ".zshrc": "bash",
};

const EXT_LANGUAGES = {
  mjs: "javascript",
  cjs: "javascript",
  jsx: "javascript",
  tsx: "typescript",
  mts: "typescript",
  cts: "typescript",
  h: "c",
  hpp: "cpp",
  cc: "cpp",
  cxx: "cpp",
  hh: "cpp",
  m: "objectivec",
  mm: "objectivec",
  ps1: "powershell",
  psm1: "powershell",
  psd1: "powershell",
  bat: "dos",
  cmd: "dos",
  yml: "yaml",
  zon: "zig",
  htm: "xml",
  html: "xml",
  xhtml: "xml",
  svg: "xml",
  vue: "xml",
  md: "markdown",
  mdx: "markdown",
  toml: "ini",
  jsonc: "json",
  json5: "json",
  kts: "kotlin",
  rs: "rust",
  py: "python",
  rb: "ruby",
  sh: "bash",
  zsh: "bash",
  cs: "csharp",
  fs: "fsharp",
};

/**
 * highlight.js language for a path, or null.
 * @param {string} path
 * @param {{getLanguage: Function}|null} hljs
 */
export function languageFor(path, hljs) {
  if (!hljs || typeof hljs.getLanguage !== "function") return null;
  const name = String(path || "").split(/[\\/]/).pop().toLowerCase();
  const candidates = [];
  if (NAME_LANGUAGES[name]) candidates.push(NAME_LANGUAGES[name]);
  const dot = name.lastIndexOf(".");
  if (dot > 0 || (dot === 0 && name.length > 1)) {
    const ext = name.slice(dot + 1);
    if (EXT_LANGUAGES[ext]) candidates.push(EXT_LANGUAGES[ext]);
    candidates.push(ext);
  }
  for (const c of candidates) {
    if (hljs.getLanguage(c)) return c;
  }
  return null;
}

function splitFragment(root, doc, count) {
  const lines = [doc.createDocumentFragment()];
  const walk = (node, classes) => {
    for (const child of Array.from(node.childNodes)) {
      if (child.nodeType === 3) {
        const parts = child.data.split("\n");
        parts.forEach((part, i) => {
          if (i > 0) lines.push(doc.createDocumentFragment());
          if (!part) return;
          let leaf = doc.createTextNode(part);
          for (let k = classes.length - 1; k >= 0; k -= 1) {
            const span = doc.createElement("span");
            if (classes[k]) span.className = classes[k];
            span.append(leaf);
            leaf = span;
          }
          lines[lines.length - 1].append(leaf);
        });
      } else if (child.nodeType === 1) {
        walk(child, classes.concat(String(child.getAttribute("class") || "")));
      }
    }
  };
  walk(root, []);
  while (lines.length < count) lines.push(doc.createDocumentFragment());
  return lines.slice(0, count);
}

/**
 * Highlight consecutive lines of one file side as one block (multi-line
 * tokens keep their context) and return one fragment per line, or null when
 * highlighting is unavailable, too large or fails.
 * @param {{hljs: object|null, purify: object|null, document: Document}} env
 * @param {string|null} language
 * @param {string[]} texts
 */
export function highlightLines(env, language, texts) {
  const { hljs, purify } = env;
  if (!language || !hljs || !purify || texts.length === 0) return null;
  const code = texts.join("\n");
  if (code.length > MAX_HIGHLIGHT_CHARS) return null;
  let html;
  try {
    html = hljs.highlight(code, { language, ignoreIllegals: true }).value;
  } catch {
    return null;
  }
  const frag = purify.sanitize(html, {
    ALLOWED_TAGS: ["span"],
    ALLOWED_ATTR: ["class"],
    RETURN_DOM_FRAGMENT: true,
  });
  return splitFragment(frag, env.document, texts.length);
}

/**
 * Wrap character ranges [start, end) of an element's text in
 * `<span class=className>`. Ranges are offsets into `el.textContent`, sorted
 * and non-overlapping. Returns the created spans.
 */
export function wrapRanges(el, ranges, className) {
  const created = [];
  if (!ranges || ranges.length === 0) return created;
  const doc = el.ownerDocument;
  const walker = doc.createTreeWalker(el, 4 /* SHOW_TEXT */);
  const nodes = [];
  for (let n = walker.nextNode(); n; n = walker.nextNode()) nodes.push(n);
  let pos = 0;
  let r = 0;
  for (const node of nodes) {
    const text = node.data;
    const nodeStart = pos;
    const nodeEnd = pos + text.length;
    pos = nodeEnd;
    while (r < ranges.length && ranges[r][1] <= nodeStart) r += 1;
    if (r >= ranges.length) break;
    if (ranges[r][0] >= nodeEnd) continue;
    const frag = doc.createDocumentFragment();
    let cursor = 0;
    let k = r;
    while (k < ranges.length && ranges[k][0] < nodeEnd) {
      const s = Math.max(ranges[k][0], nodeStart) - nodeStart;
      const e = Math.min(ranges[k][1], nodeEnd) - nodeStart;
      if (s > cursor) frag.append(doc.createTextNode(text.slice(cursor, s)));
      if (e > s) {
        const span = doc.createElement("span");
        span.className = className;
        span.textContent = text.slice(s, e);
        frag.append(span);
        created.push(span);
      }
      cursor = Math.max(cursor, e);
      if (ranges[k][1] > nodeEnd) break;
      k += 1;
    }
    if (cursor < text.length) frag.append(doc.createTextNode(text.slice(cursor)));
    node.parentNode.replaceChild(frag, node);
  }
  return created;
}

/** Undo wrapRanges for one class (merges the text back). */
export function unwrapRanges(root, className) {
  for (const span of Array.from(root.querySelectorAll("span." + className))) {
    const parent = span.parentNode;
    span.replaceWith(...Array.from(span.childNodes));
    parent.normalize();
  }
}
