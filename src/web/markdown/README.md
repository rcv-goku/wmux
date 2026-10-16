# `src/web/markdown`: markdown viewer panel

PanelKind `markdown` (ARCHITECTURE ADR-6.11), entry
`https://markdown.wmux.example/markdown/index.html`. Renders one markdown file
with GitHub-flavored markdown, syntax highlighting and Mermaid diagrams, and
offers live reload, link routing, find, zoom and typography, a TextEdit
(source) mode, copy actions and viewer navigation keys.

Covers: `panels-markdown-rendering`, `panels-markdown-diagrams`,
`panels-markdown-frontmatter`, `panels-markdown-live-reload`,
`panels-markdown-link-routing`, `panels-markdown-images`,
`panels-markdown-typography`, `panels-markdown-zoom-shortcuts`,
`panels-markdown-textedit-mode`, `panels-markdown-copy-toolbar`,
`panels-viewer-keyboard-navigation`, `panels-markdown-find` (page side; the
native side is described below).

| File | Purpose |
|---|---|
| `index.html` | page shell: toolbar, typography popover, find bar, preview, File unavailable state, editor |
| `markdown.js` | entry module: imports the vendored libraries and starts the app |
| `app.js` | the application: bridge, loading, live reload, modes, find, links, copy, keys |
| `render.js` | markdown -> sanitized DOM (frontmatter, slugs, task lists, code blocks, images) |
| `links.js` | link and image routing rules (pure) |
| `find.js` | in-page find (highlights, counter, wrap-around) |
| `diagrams.js` | lazy Mermaid rendering and inline error boxes |
| `typography.js` | font size / family / max width rules (pure) |
| `keymap.js` | action ids, default bindings, scroll targets |
| `strings.js` | user-visible strings (`tr()` keys) |
| `markdown.css` | layout and the GitHub-like document style on the `--wmux-*` tokens |

Libraries (all under `../_vendor/`, see the `SOURCE.md` in each directory):
markdown-it 15.0.2 (GFM tables, strikethrough, autolinks), markdown-it-footnote
4.0.0, DOMPurify 3.4.17 (Apache-2.0 option), highlight.js 11.12.0 (prebuilt
core + common languages, GitHub light/dark styles), mermaid 11.17.2 (loaded
with a `<script src>` only when a page contains a mermaid block). Task lists and
heading ids are implemented here as small markdown-it rules.

## Native contract

Names follow ADR-6.5. Methods that cmux does not name live under the panel's
own namespace, `panel.markdown.*` (handled by the kind's `on_message`).

### `panel.init`

| Key | Used for |
|---|---|
| `params.path` | the file (also shown in the File unavailable state) |
| `params.display_path` | shown to the user and used for the title (basename); defaults to `path` |
| `params.text` | optional: render this text instead of calling `panel.read_file` |
| `params.base_url` | optional: the per-panel file host `https://f-<16hex>.wmux.example/` mapped to the file's directory (also accepted from `panel.read_file`) |
| `params.encoding` | optional: encoding to pass back on save |
| `params.font_size` | optional: `cmux markdown open --font-size` override (pt) |
| `params.display_mode` | optional: `"preview"` (default) or `"text"` |
| `params.find` | optional: open the find bar with this query (global search hits) |
| `settings` | `markdown.fontSize`, `markdown.fontFamily`, `markdown.maxWidth` (flat dotted keys, or `{markdown: {...}}`), `fileEditor.wordWrap` (bool) |
| `state` | the last `panel.state_changed` state (below) when restored |
| `keymap` | effective bindings; replaces the defaults in `keymap.js` |

The page sets the tab title with `panel.set_title {title: <basename>}`.

### Methods called by the page

| Method | Params -> result | Notes |
|---|---|---|
| `panel.read_file` | `{}` -> `{text, encoding?, base_url?, path?, display_path?}` | own file only. `file_not_found` / `not_found` show "File unavailable". Other errors are retried 3 times (150 ms, 300 ms, 450 ms) |
| `panel.write_file` | `{text, encoding?}` -> `{encoding?}` | own file only, atomic, encoding preserved (`encoding` is what `read_file` returned). `text` uses the file's line breaks: the editor reports LF, and the page converts back to CRLF when the text last read from disk used CRLF. Must publish the committed-write signal so other viewers refresh |
| `panel.watch_file` | `{on: true}` -> `{}` | start file watching; changes arrive as `panel.markdown.file_changed` |
| `panel.set_dirty` | `{dirty}` | TextEdit buffer differs from disk |
| `panel.state_changed` | `{state}` | see "Session state" |
| `panel.clipboard_write` | `{text, html?}` | Copy code, Copy as Markdown, Copy as HTML (`html` = rendered HTML, `text` = its plain text; native writes CF_HTML + CF_UNICODETEXT), Copy URL |
| `panel.open_in_browser` | `{url}` | http(s) links. Native applies the browser link settings (embedded browser tab in the same pane, or the system browser) |
| `panel.open_external` | `{url}` | non-http schemes: `mailto:`, `tel:`, `vscode://`, `slack://`, ... (OS handler) |
| `panel.open_file` | `{path}` | non-markdown local paths (file-open router); also the fallback when `panel.markdown.open` is not implemented |
| `panel.markdown.open` | `{path, fragment?}` -> `{}` | markdown links (`.md .markdown .mkd .mdx`). `path` is as written in the document (decoded, `?query` and `#fragment` stripped; `file:` URLs converted to paths). Native resolves it against the document's directory, then the working directory, and opens a focused sibling markdown tab in the same pane. `file_not_found` makes the page show "File not found" |
| `panel.markdown.resolve_links` | `{paths: [..]}` -> `{exists: {"<path>": bool}}` | existence check for inline code spans that look like markdown paths (`docs/x.md`); at most 200 paths per call, cached per page load |
| `panel.markdown.resolve_image` | `{path}` -> `{url}` | absolute local image paths (`C:\x.png`, `/x.png`, `\\srv\x.png`, `file:` URLs). `url` must be `https://*.wmux.example/...` or `data:image/...`; anything else is ignored |
| `panel.markdown.approve_remote_image` | `{url}` -> `{}` | "Load image" on a blocked remote image: record the approval for exactly this URL for this panel and allow it in the panel's CSP (native rewrites the page CSP, see `_shared/README.md`), then the page sets `<img src=url>` |
| `panel.markdown.list_fonts` | `{}` -> `{families: [..]}` | font picker (EnumFontFamiliesExW); the page falls back to a short built-in list |
| `panel.markdown.set_defaults` | `{fontSize, fontFamily, maxWidth}` -> `{}` | "Set as default for new viewers": write `markdown.fontSize`, `markdown.fontFamily`, `markdown.maxWidth` |

### Events pushed by native

| Event | Payload | Effect |
|---|---|---|
| `panel.markdown.file_changed` | `{status: "changed" \| "deleted" \| "unavailable", text?, encoding?}` | `changed` with `text` renders it, without `text` the page calls `panel.read_file` (only the newest read is applied). `deleted` / `unavailable` show "File unavailable" until the next `changed`. Scroll position and the find needle survive re-renders. A dirty TextEdit buffer is never replaced |
| `panel.markdown.settings` | settings object (same shapes as `panel.init.settings`) | new defaults: every value a viewer has not customized follows them |
| `panel.markdown.command` | `{action}` | run a panel action from the palette or a native shortcut: `markdownZoomIn`, `markdownZoomOut`, `markdownZoomReset`, `find`, `findNext`, `findPrevious`, `hideFind`, `saveFilePreview`, the `diffViewerScroll*` ids, and the wmux-only `wmux.markdownTogglePreview` (preview/TextEdit) and `wmux.markdownRefresh` |
| `panel.markdown.find` | `{query}` | open the find bar pre-filled (global search hit) |
| `theme`, `keymap`, `panel.key_sequence` | shared | handled by `_shared/` |

### Session state (`panel.state_changed`)

`{v: 1, display_mode: "preview" | "text", typography: {fontSize, fontFamily,
maxWidth}, approved_images: [url, ...] (last 200), find: "<needle>"}`. Native
can report `display_mode` in `file.open` replies from it.

## Behavior notes

- **Rendering.** Raw HTML in markdown is allowed and sanitized by DOMPurify:
  `script`, `style`, forms and form controls, frames, `object`/`embed`,
  `meta`/`base`/`link` and `template` are removed, as are `style`, `srcset`,
  `target`, `ping` attributes and `javascript:`/`vbscript:`/`data:` link
  targets (`data:image/*` images stay). Table alignment becomes the `align`
  attribute. Headings get GitHub slugs (`Setup`, `Setup` -> `setup`,
  `setup-1`). Leading YAML frontmatter becomes a collapsed "Show frontmatter"
  disclosure with highlighted YAML.
- **Diagrams.** ```` ```mermaid ```` blocks keep the source in a hidden
  `pre.wmux-source` and render into `.wmux-diagram-output` with
  `securityLevel: "strict"` and a theme that follows the light/dark scheme.
  Errors show "Mermaid error: <message>" inline. Mermaid's `<style>` and
  `style=""` output are re-applied through the CSSOM (CSP).
- **Images.** Relative paths are resolved against `base_url`. URLs that would
  leave the host are not loaded. Remote http(s) images show the "Remote image
  blocked" placeholder with Load image / Open URL / Copy URL ("Copied" for
  1.2 s). A placeholder for a linked image follows the link.
- **Links.** Every click (and middle click) in the document is intercepted.
  `#fragment` scrolls smoothly in the page. Other targets go through the
  methods above. `target` attributes are removed. Documents cannot run script,
  so there is no `window.open`.
- **Typography.** `fontSize` 8..96 pt (zoom = size / 15), `maxWidth`
  320..2400 px in steps of 20, `fontFamily` "" = system stack. Code stays
  monospace. A viewer keeps its own values. When defaults change, each value
  equal to the previous default follows the new one (per value).
- **Zoom.** `markdownZoomIn` / `markdownZoomOut` / `markdownZoomReset` (Ctrl+=,
  Ctrl+-, Ctrl+0 by default): 1 pt steps, clamped, reset = current default.
- **Find.** Ctrl+F (`find`) in preview mode: case-insensitive literal search
  over visible text (not hidden sources, code-copy buttons or diagrams), `<mark>`
  highlights, the current match in orange and scrolled to the center, "n/m"
  counter, Enter / Shift+Enter, F3 / Shift+F3, Escape closes and clears. At most
  10000 highlights. Not available in TextEdit mode.
- **TextEdit mode.** "Show TextEdit" swaps the preview for a plain textarea on
  the raw source ("Show Preview" goes back). Revert re-reads the file and Save
  (or Ctrl+S, `saveFilePreview`) calls `panel.write_file`. Both are enabled only
  when dirty. While the buffer is dirty, external changes only show a notice,
  and the preview renders the buffer.
- **Navigation keys.** With the preview focused and no text field focused:
  `j`/`k` (40 px), Ctrl+D/Ctrl+U (half page), Ctrl+N/Ctrl+P, Shift+G (bottom),
  `g g` (top). Smooth scrolling unless reduced motion is on.
- **Copy.** Code blocks get a "Copy code" button (raw code). The toolbar has
  Copy as Markdown (source) and Copy as HTML (rendered HTML without the panel's
  buttons), confirmed with "Copied as Markdown" / "Copied as HTML".

## CSP

```
default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data: https://*.wmux.example; media-src 'self' https://*.wmux.example; font-src 'self'; frame-src 'none'; worker-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'
```

No trusted-types directive: DOMPurify and Mermaid use HTML sinks. Native adds
approved remote image URLs to `img-src` by rewriting the page (ADR-6.7).

## Tests

`test/web-node/markdown.test.mjs` (node:test + jsdom, mock
`window.chrome.webview`):

```sh
npm install --prefix /tmp/wmux-web-test-deps --ignore-scripts jsdom@26
WMUX_WEB_TEST_DEPS=/tmp/wmux-web-test-deps node --test 'test/web-node/*.test.mjs'
```
