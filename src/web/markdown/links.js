/**
 * Link and image routing rules of the markdown panel (pure functions, no DOM).
 *
 * classifyLink(href) decides where a clicked link goes:
 *   {action: "anchor",   id}               in-page #fragment (smooth scroll)
 *   {action: "browser",  url}              http(s): the wmux browser (link settings apply natively)
 *   {action: "external", url}              other schemes (mailto:, tel:, vscode://, ...): OS handler
 *   {action: "markdown", path, fragment}   a .md/.markdown/.mkd/.mdx path: sibling markdown tab
 *   {action: "file",     path}             any other local path: the file-open router
 *   {action: "none"}                       empty, script or otherwise unsafe targets
 * Paths stay as written (relative to the document); native resolves them
 * against the document's directory, then the working directory.
 */

export const MARKDOWN_EXTENSIONS = Object.freeze([".md", ".markdown", ".mkd", ".mdx"]);

/** Upper bound for hrefs and paths handed to native. */
export const MAX_LINK_LENGTH = 4096;

const SCHEME_RE = /^([a-zA-Z][a-zA-Z0-9+.-]*):/;
// A Windows drive letter: "C:\docs", "C:%5Cdocs%5Ca.md" (as markdown-it writes
// it) and drive-relative "c:notes.md". One letter before ":" is never treated
// as a URL scheme, so "c:tool.exe" cannot reach the OS URL handler.
const DRIVE_RE = /^[a-zA-Z]:/;
// Prefix used to detect relative image paths that climb above the file host root.
const PROBE_ROOT = "/wmux-probe-root";
const BLOCKED_SCHEMES = new Set(["javascript", "vbscript", "data", "blob", "about", "filesystem"]);
const CONTROL_RE = /[\u0000-\u001f\u007f]/;

function safeDecode(text) {
  try {
    return decodeURIComponent(text);
  } catch {
    return text;
  }
}

/** Whether a path (query and fragment already removed) names a markdown file. */
export function isMarkdownPath(path) {
  if (typeof path !== "string") return false;
  const lower = path.toLowerCase();
  return MARKDOWN_EXTENSIONS.some((ext) => lower.endsWith(ext) && lower.length > ext.length);
}

/** Split "a/b.md?x=1#frag" into {path: "a/b.md", fragment: "frag"} (both decoded). */
export function splitPath(href) {
  let rest = href;
  let fragment = "";
  const hash = rest.indexOf("#");
  if (hash >= 0) {
    fragment = safeDecode(rest.slice(hash + 1));
    rest = rest.slice(0, hash);
  }
  const query = rest.indexOf("?");
  if (query >= 0) rest = rest.slice(0, query);
  return { path: safeDecode(rest), fragment };
}

/** Local path of a file: URL ("file:///C:/a%20b.md" -> "C:/a b.md", UNC -> "//server/share/x"). */
export function fileUrlToPath(href) {
  let url;
  try {
    url = new URL(href);
  } catch {
    return null;
  }
  if (url.protocol !== "file:") return null;
  let path = safeDecode(url.pathname);
  if (/^\/[a-zA-Z]:/.test(path)) path = path.slice(1);
  if (url.hostname && url.hostname !== "localhost") path = "//" + url.hostname + path;
  return path;
}

/**
 * Classify a link target.
 * @param {unknown} rawHref the anchor's href attribute (not the resolved .href)
 */
export function classifyLink(rawHref) {
  if (typeof rawHref !== "string") return { action: "none" };
  const href = rawHref.trim();
  if (href === "" || href.length > MAX_LINK_LENGTH || CONTROL_RE.test(href)) {
    return { action: "none" };
  }
  if (href.startsWith("#")) {
    const id = safeDecode(href.slice(1));
    return id === "" ? { action: "none" } : { action: "anchor", id };
  }
  if (href.startsWith("//") && !href.startsWith("///")) {
    return classifyLink("https:" + href);
  }
  if (!DRIVE_RE.test(href)) {
    const scheme = SCHEME_RE.exec(href);
    if (scheme) {
      const name = scheme[1].toLowerCase();
      if (BLOCKED_SCHEMES.has(name)) return { action: "none" };
      if (name === "http" || name === "https") {
        try {
          const url = new URL(href);
          return url.hostname ? { action: "browser", url: url.href } : { action: "none" };
        } catch {
          return { action: "none" };
        }
      }
      if (name === "file") {
        // The URL parser already drops ?query and #fragment from the path.
        const path = fileUrlToPath(href);
        if (!path) return { action: "none" };
        const hash = href.indexOf("#");
        const fragment = hash >= 0 ? safeDecode(href.slice(hash + 1)) : "";
        if (isMarkdownPath(path)) return { action: "markdown", path, fragment };
        return { action: "file", path };
      }
      return { action: "external", url: href };
    }
  }
  const split = splitPath(href);
  if (split.path === "") {
    return split.fragment ? { action: "anchor", id: split.fragment } : { action: "none" };
  }
  if (isMarkdownPath(split.path)) {
    return { action: "markdown", path: split.path, fragment: split.fragment };
  }
  return { action: "file", path: split.path };
}

/**
 * Whether an inline code span looks like a markdown path worth checking
 * (`docs/foo.md`, `../x.md`, `README.md#install`). URLs and text with spaces are not.
 */
export function looksLikeMarkdownPath(text) {
  if (typeof text !== "string") return false;
  const value = text.trim();
  if (value === "" || value.length > 1024 || /\s/.test(value)) return false;
  if (SCHEME_RE.test(value) && !DRIVE_RE.test(value)) return false;
  return isMarkdownPath(splitPath(value).path);
}

/**
 * How an <img src> is served:
 *   {kind: "data", url}       data: URI, rendered as is
 *   {kind: "local", url}      relative path resolved against the panel's file host
 *   {kind: "host", url}       already a URL on the panel's file host
 *   {kind: "absolute", path}  absolute or drive-relative local path, or file: URL (native maps it)
 *   {kind: "outside", path}   relative path that climbs above the file host root
 *                             ("../x.png" when the host maps the document's directory):
 *                             native resolves it against the document's directory
 *   {kind: "remote", url}     http(s) elsewhere: blocked until approved
 *   {kind: "none"}            anything else (not loaded)
 *
 * @param {unknown} rawSrc the src attribute
 * @param {string|null} baseUrl the panel's file host, "https://f-<16hex>.wmux.example/" (or a sub path)
 */
export function classifyImage(rawSrc, baseUrl) {
  if (typeof rawSrc !== "string") return { kind: "none" };
  const src = rawSrc.trim();
  if (src === "" || src.length > 65536 * 16 || CONTROL_RE.test(src)) return { kind: "none" };
  if (/^data:image\//i.test(src)) return { kind: "data", url: src };
  if (DRIVE_RE.test(src) || src.startsWith("\\\\") || /^%5[cC]%5[cC]/.test(src)) {
    return { kind: "absolute", path: safeDecode(src) };
  }
  if (src.startsWith("//")) return classifyImage("https:" + src, baseUrl);
  const scheme = SCHEME_RE.exec(src);
  if (scheme) {
    const name = scheme[1].toLowerCase();
    if (name === "file") {
      const path = fileUrlToPath(src);
      return path ? { kind: "absolute", path } : { kind: "none" };
    }
    if (name !== "http" && name !== "https") return { kind: "none" };
    let url;
    try {
      url = new URL(src);
    } catch {
      return { kind: "none" };
    }
    const base = parseBase(baseUrl);
    if (base && url.origin === base.origin) return { kind: "host", url: url.href };
    return { kind: "remote", url: url.href };
  }
  if (src.startsWith("/")) return { kind: "absolute", path: safeDecode(src.split(/[?#]/)[0]) };
  const base = parseBase(baseUrl);
  if (!base) return { kind: "none" };
  try {
    const url = new URL(src, base.href);
    if (url.origin !== base.origin) return { kind: "none" };
    // URL resolution stops at the host root, so "../x.png" would silently turn
    // into "<root>/x.png", a different file. Let native resolve those.
    const probe = new URL(src, base.origin + PROBE_ROOT + base.pathname);
    if (!probe.pathname.startsWith(PROBE_ROOT + "/")) {
      return { kind: "outside", path: safeDecode(src.split(/[?#]/)[0]) };
    }
    return { kind: "local", url: url.href };
  } catch {
    return { kind: "none" };
  }
}

/** The file host base as a URL (https on *.wmux.example only), or null. */
export function parseBase(baseUrl) {
  if (typeof baseUrl !== "string" || baseUrl === "") return null;
  try {
    const url = new URL(baseUrl);
    if (url.protocol !== "https:" || !/\.wmux\.example$/i.test(url.hostname)) return null;
    if (!url.pathname.endsWith("/")) url.pathname += "/";
    url.search = "";
    url.hash = "";
    return url;
  } catch {
    return null;
  }
}

/** A URL native may hand back for an image: data:image/* or https on *.wmux.example. */
export function isServableImageUrl(value) {
  if (typeof value !== "string") return false;
  if (/^data:image\//i.test(value)) return true;
  try {
    const url = new URL(value);
    return url.protocol === "https:" && /\.wmux\.example$/i.test(url.hostname);
  } catch {
    return false;
  }
}

/** Last path segment ("C:\\docs\\README.md" -> "README.md"). */
export function basename(path) {
  if (typeof path !== "string") return "";
  const parts = path.split(/[\\/]+/).filter((part) => part !== "");
  return parts.length ? parts[parts.length - 1] : "";
}
