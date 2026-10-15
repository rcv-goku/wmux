# `src/web/_shared`: web panel runtime

Shared code for every wmux web panel (ARCHITECTURE ADR-6). A panel is a small
local web app in `src/web/<app>/`, loaded by a WebView2 controller at
`https://<app>.wmux.example/<app>/index.html`. The virtual host maps to the
whole web root, so a page reaches this directory as `../_shared/`.

| File | Purpose |
|---|---|
| `wmux-bridge.js` | JSON bridge to native: calls, events, ready handshake, panel context |
| `theme.js` | applies the terminal theme (`panel.init.theme`, `theme` events) to CSS variables |
| `theme.css` | the `--wmux-*` design tokens and their defaults |
| `base.css` | element styles built on the tokens (imports `theme.css`) |
| `keys.js` | keyboard integration with the native KeyRouter |
| `strings.js` | `tr(key, default)` for user-visible text |

Everything is plain ES2020 modules and CSS: no build step, no npm, no
bundler. `zig build` installs `src/web/**` as-is to `SHARE\wmux\web\`; set
`WMUX_WEB_DIR=<repo>\src\web` to serve the live sources while developing and
`WMUX_WEB_DEVTOOLS=1` to get DevTools. Third-party libraries come only from
`../_vendor/` (see `_vendor/README.md`).

## Writing a panel

```html
<!doctype html>
<html lang="en" dir="ltr">
  <head>
    <meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'self'; connect-src 'self'; img-src 'self' data: https://*.wmux.example; object-src 'none'; base-uri 'none'; form-action 'none'">
    <meta name="referrer" content="no-referrer">
    <title>Example</title>
    <link rel="icon" href="data:,">
    <link rel="stylesheet" href="../_shared/base.css">
    <link rel="stylesheet" href="example.css">
    <script type="module" src="example.js"></script>
  </head>
  <body>…</body>
</html>
```

```js
// example.js
import { wmux } from "../_shared/wmux-bridge.js";
import "../_shared/theme.js";                 // theme sync starts on import
import { installKeys } from "../_shared/keys.js";
import { applyStrings } from "../_shared/strings.js";
import { t } from "./strings.js";             // this panel's keys + English defaults

async function main() {
  applyStrings(document);
  const keys = installKeys();
  keys.handle("exampleNext", () => selectNext());

  const ctx = await wmux.ready();             // {kind, surface_id, params, state, theme, keymap, settings}
  await wmux.panel.setTitle(t("example.title"));
  const workspaces = await wmux.call("workspace.list"); // must be in the kind's allowlist
}

main();
```

Rules:

- One `<meta http-equiv="Content-Security-Policy">`, first in `<head>` after
  `<meta charset>`. No inline `<script>`, no inline event handlers, no
  `style="…"` attributes and no `<style>` elements: the CSP blocks them. Setting
  styles from script through the CSSOM (`el.style.setProperty(…)`) is allowed.
- Keep `<link rel="icon" href="data:,">`: without it the runtime requests
  `/favicon.ico`, which the virtual host answers with a 404 console error.
- Never assign untrusted text to `innerHTML`; use `textContent` and DOM APIs.
  Untrusted markup (markdown, previews) goes through the vendored DOMPurify.
  Pages without HTML sinks should also add
  `require-trusted-types-for 'script'; trusted-types 'none'` to their CSP (the
  About panel does).
- Navigation is locked to the panel's origin. Open links with
  `wmux.panel.openExternal(url)` (OS browser) or `wmux.panel.openInBrowser(url)`
  (wmux browser tab); a plain `<a href>` to another origin is cancelled by native.
- User-visible text goes through `tr()` with keys in `src/web/<app>/strings.js`.
- Colors, fonts, spacing and radii come from the `--wmux-*` tokens.
- Keep panel state small: `panel.state_changed` is capped at 64 KiB.

### Content Security Policy

The baseline is ADR-6.7 plus `base-uri 'none'` and `form-action 'none'`
(neither falls back to `default-src`):

```
default-src 'self'; script-src 'self'; connect-src 'self'; img-src 'self' data: https://*.wmux.example; object-src 'none'; base-uri 'none'; form-action 'none'
```

Panels that fetch synthesized data from per-panel token hosts
(`https://d-<16hex>.wmux.example/`) need `connect-src 'self' https://*.wmux.example`.
CSP host wildcards only cover a whole leftmost label (`*.wmux.example`); a
partial label such as `https://d-*.wmux.example` is not valid CSP and browsers
drop it. Only the panel's own hosts are mapped in its webview, so the wildcard
reaches nothing else. `frame-ancestors` has no effect in a meta tag; do not add it.
A policy delivered by meta can only be tightened by native, never loosened, so
a panel whose CSP must vary at runtime (markdown remote images) gets its page
rewritten by native.

## Bridge API (`wmux-bridge.js`)

```js
import { wmux, cmux, WmuxError, ErrorCode } from "../_shared/wmux-bridge.js";
```

The module also defines the globals `wmux` and `cmux` (read-only) for
non-module code. Every module that imports the bridge shares one instance.

| Member | Description |
|---|---|
| `wmux.ready(options?)` | Sends `panel.ready` once and resolves with the `panel.init` payload. Rejects with `timeout` after `options.timeoutMs` (default 10000; 0 waits forever) or `unavailable` outside wmux; call again to retry. |
| `wmux.call(method, params?, options?)` | Sends a request and resolves with its `result` (`null` when absent). `params` must be a JSON object (omitted or `null` means `{}`). `options.timeoutMs` (default 30000; 0 or `Infinity` = none), `options.signal` (`AbortSignal`, rejects with `cancelled`). |
| `wmux.send(method, params?)` | Fire-and-forget: no `id`, native never replies. Returns `false` instead of throwing. |
| `wmux.on(event, listener)` | Subscribes to a native event; `"*"` receives all. `listener(payload, eventName)`. Returns an unsubscribe function. |
| `wmux.once(event, listener)` / `wmux.off(event, listener)` | One-shot listener; removal. |
| `wmux.context` | The `panel.init` payload, or `null` before it arrives (read-only). |
| `wmux.theme` | The latest theme payload, or `null`. |
| `wmux.available` | `true` inside a WebView2 host (`window.chrome.webview` exists). |
| `wmux.panel.*` | Helpers for the panel-local methods, below. |
| `wmux.setDebug(true)` | Logs all traffic with `console.debug`. |
| `cmux(method, params?, options?)` | Alias of `wmux.call` (cmux custom-sidebar code). |

Failed calls reject with a `WmuxError` (`err instanceof WmuxError`):
`err.code`, `err.message`, `err.data` and, when native sends them, `err.reason`,
`err.action`, `err.details`; `err.method` names the call. Codes are the v2 codes
of ADR-3.5 (`ErrorCode.METHOD_NOT_FOUND === "method_not_found"`, …). The bridge
produces these itself:

| Code | When |
|---|---|
| `unavailable` | not inside wmux, or posting to the host failed |
| `timeout` | no reply within `timeoutMs`; `data = {stage: "bridge", deadline_ms, retryable}` |
| `cancelled` | the `AbortSignal` fired |
| `invalid_request` | empty method (`"Missing method"`) |
| `invalid_params` | `params` not an object; `panel.state_changed` state above 64 KiB (`data = {bytes, limit}`) |
| `encode_error` | params not JSON-serializable (`"Failed to encode JSON"`) |
| `internal_error` | malformed error reply from native |

A reply that arrives after its call timed out or was cancelled is dropped.
Native's own UI-lane deadline is 10 s (ADR-3.2) and arrives as a regular
`timeout` error with `data.stage = "main_actor"`.

### Panel-local methods (`wmux.panel`)

Always allowed for every kind (`"panel.*"` is implicit in the allowlist).

| Helper | Method and params |
|---|---|
| `setTitle(title)` | `panel.set_title {title}` |
| `setDirty(dirty)` | `panel.set_dirty {dirty}` |
| `setState(state)` | `panel.state_changed {state}`: kept for the session snapshot and "recently closed"; also updates `wmux.context.state` |
| `openExternal(url)` | `panel.open_external {url}` |
| `openInBrowser(url)` | `panel.open_in_browser {url}` |
| `openFile(path)` | `panel.open_file {path}` (file-open router) |
| `clipboardWrite(text, html?)` | `panel.clipboard_write {text, html?}`: honored only within 2 s of a user gesture |
| `requestFocus()` | `panel.request_focus {}` |
| `keyCapture(on)` | `panel.key_capture {on}` (prefer `keys.startCapture()`) |
| `subscribe(categories)` | `panel.subscribe {categories: [...]}`: events then arrive as `cmux.event` |
| `notify(title, body?)` | `panel.notify {title, body?}` |

`panel.read_file`, `panel.write_file` and `panel.watch_file` (own file only)
go through `wmux.call` with the parameters their owning WP defines.
Kind-specific methods are named `panel.<kind>.<verb>` and handled by the kind's
`on_message`; for example the About panel calls `panel.about.info`.

### Wire protocol

Every message carries `"v": 1`. Pages always post plain objects, so native reads
them with `get_WebMessageAsJson`; native posts with `PostWebMessageAsJson`.

```
page -> native   {"v":1,"id":"c17","method":"workspace.list","params":{}}
                 {"v":1,"method":"panel.state_changed","params":{"state":{}}}     (no id: no reply)
native -> page   {"v":1,"id":"c17","ok":true,"result":{...}}
                 {"v":1,"id":"c17","ok":false,"error":{"code":"forbidden","message":"...","data":{...}}}
                 {"v":1,"event":"panel.init","payload":{...}}
                 {"v":1,"event":"theme","payload":{...}}
                 {"v":1,"event":"cmux.event","payload":<events frame>}
```

- Request ids are strings `"c<n>"`, unique per page load; native echoes them.
- Native identifies the sender by the controller that raised
  `WebMessageReceived`. Nothing the page sends is trusted as identity.
- Dispatch: `PanelKind.on_message` first, then the RPC registry with
  `Origin.in_process{.web_panel}`; methods outside the kind's allowlist fail
  with `forbidden`.
- A message with an `id` gets exactly one reply.
- The bridge ignores messages whose `v` is not 1 (missing `v` is accepted with a
  warning), malformed JSON, and replies to unknown ids.

Ready handshake: the page imports the bridge (which starts listening), then
calls `wmux.ready()`, which posts `panel.ready`. Native replies to it and pushes
`panel.init`; the payload may instead be returned as the `panel.ready` result
(an object with a string `kind`), and the bridge treats both the same way. Native
must not post `panel.init` before `panel.ready`: messages sent before the page
listens are lost.

`panel.init` payload:

| Key | Meaning |
|---|---|
| `kind` | panel kind id (`"about"`) |
| `surface_id` | UUID of the tab hosting the panel |
| `params` | creation params (`ops.surface.create(…, .{ .web = .{ .kind, .params } })`) |
| `state` | last `panel.state_changed` state when restored, else `null` |
| `theme` | theme payload (below) |
| `keymap` | effective bindings for this panel (below) |
| `settings` | settings the kind exposes to the page |

## Theme (`theme.js`, `theme.css`, `base.css`)

Importing `theme.js` applies `panel.init.theme` and every later `theme` event.
Until the first theme arrives `<html>` stays transparent, so the host's
`DefaultBackgroundColor` (the terminal background) shows without a flash.
Outside wmux the defaults in `theme.css` apply and follow
`prefers-color-scheme`.

Theme payload sent by native (`web/theme.zig`); snake_case keys, kebab-case and
camelCase are accepted too:

| Key | Value |
|---|---|
| `background`, `foreground` | `"#rrggbb"` |
| `palette` | array of 16 colors |
| `cursor` | color, or `{color, text}`; `cursor_color` / `cursor_text` also work |
| `selection` | background color, or `{background, foreground}`; `selection_background` / `selection_foreground` also work |
| `accent` | wmux accent color |
| `sidebar` | `{background, foreground, active_background, active_foreground, border}` |
| `font_family` | family name or array of names |
| `font_size_px` | **CSS px** (DIPs) = points x 96 / 72; `font_size_pt` is converted. WebView2 applies the monitor scale itself, so physical pixels would be scaled twice. |
| `background_opacity` | 0..1 |
| `scheme` | `"dark"` or `"light"` (derived from the background when absent) |
| `high_contrast` | `SPI_GETHIGHCONTRAST` |
| `reduced_motion` | optional: `SPI_GETCLIENTAREAANIMATION` off |

Colors may also be `"#rgb"`, bare hex, `"rgb(r, g, b)"`, `{r, g, b}` or `[r, g, b]`.
Missing values fall back to defaults; derived colors keep WCAG contrast (link
and muted text 4.5:1, focus ring 3:1).

CSS custom properties on `<html>`:

| Group | Tokens |
|---|---|
| terminal | `--wmux-bg`, `--wmux-fg`, `--wmux-bg-rgb`, `--wmux-fg-rgb` (`"r g b"` for `rgb(var(--wmux-bg-rgb) / 0.5)`), `--wmux-bg-opacity`, `--wmux-palette-0` … `--wmux-palette-15`, `--wmux-cursor`, `--wmux-cursor-text`, `--wmux-selection-bg`, `--wmux-selection-fg` |
| accent | `--wmux-accent`, `--wmux-accent-fg`, `--wmux-accent-rgb` |
| sidebar | `--wmux-sidebar-bg`, `--wmux-sidebar-fg`, `--wmux-sidebar-active-bg`, `--wmux-sidebar-active-fg`, `--wmux-sidebar-border` |
| type | `--wmux-font-mono` (terminal font + fallbacks), `--wmux-font-size` (terminal size), `--wmux-font-ui`, `--wmux-font-size-ui`, `--wmux-line-height` |
| derived | `--wmux-surface`, `--wmux-surface-raised`, `--wmux-hover`, `--wmux-pressed`, `--wmux-border`, `--wmux-border-strong`, `--wmux-fg-muted`, `--wmux-focus-ring`, `--wmux-link`, `--wmux-scrollbar-thumb`, `--wmux-scrollbar-thumb-hover`, `--wmux-scrollbar-track` |
| aliases | `--wmux-black` … `--wmux-white`, `--wmux-bright-black` … `--wmux-bright-white`, `--wmux-danger`, `--wmux-success`, `--wmux-warning`, `--wmux-info` |
| static | `--wmux-space-1` … `--wmux-space-6`, `--wmux-radius-sm`, `--wmux-radius`, `--wmux-radius-lg`, `--wmux-focus-ring-width`, `--wmux-focus-ring-offset`, `--wmux-shadow`, `--wmux-motion-duration`, `--wmux-motion-easing` |

Attributes on `<html>`: `data-wmux-theme` (`host` or `default`),
`data-wmux-scheme` (`dark` or `light`; also sets `color-scheme`),
`data-wmux-high-contrast="true"`, `data-wmux-reduced-motion="true"`.
`base.css` gives focus-visible rings, thin themed scrollbars, controls, and
turns animations off for `prefers-reduced-motion` or the host flag. Windows
contrast themes (`forced-colors: active`) override the tokens with system colors.

Script API: `applyTheme(payload | null, root?)`, `currentTheme()`,
`onThemeChange(fn)`, `normalizeTheme(payload)`, `themeProperties(theme)`,
`installTheme()` (runs on import; idempotent) and the color helpers
`parseColor`, `toHex`, `luminance`, `contrastRatio`, `mix`. `document` also
receives a `wmux:themechange` event with the normalized theme.

## Keyboard (`keys.js`)

Native offers every key that WebView2 reports through `AcceleratorKeyPressed`
to the KeyRouter first; keys it consumes never reach the page. WebView2 reports
only accelerators: keys pressed with Ctrl or Alt, keys without a character
(F1–F24, arrows, Home/End, PgUp/PgDn, Insert, Delete) and Escape. Bare and
Shift-only printable keys, Enter, Tab, Space, Backspace and the mouse X buttons
reach only the page. `keys.js` covers them.

```js
import { installKeys } from "../_shared/keys.js";
const keys = installKeys();                       // one layer per page
keys.handle("diffViewerScrollDown", ({ event }) => scroll(40));
keys.bindingsFor("diffViewerScrollDown");         // ["j"], for hints
const release = keys.startCapture();              // shortcut recorder: KeyRouter skips this panel
release();
```

`panel.init.keymap` (and an optional later `keymap` event) holds the effective
bindings whose when-clause holds in this panel:

```json
{ "diffViewerScrollDown": ["j"], "diffViewerScrollToTop": ["g g"], "closeTab": ["ctrl+w", "ctrl+shift+w"] }
```

Values are a binding string or an array of them; a binding is one stroke or a
two-stroke chord written `"g g"` or as a nested array `["ctrl+b", "c"]`.
Strokes follow ADR-8.3: `ctrl`, `shift`, `alt`, `win` joined with `+`, letters
matched by virtual key, digits and punctuation by US key position. An object
`{"keys": [...]}` or a list `[{"action", "keys"}]` also works.

Behavior for a keydown, mouse X1 (`mouse4`) or X2 (`mouse5`):

1. Text fields keep typing and caret keys: while one has focus, only Ctrl, Alt
   or Win combinations, Escape and F-keys can match (letters, digits, Enter,
   Tab, Space, Backspace, Delete, arrows, Home/End and PgUp/PgDn, with or
   without Shift, stay with the field). Enter and Space on buttons and links
   keep activating them; IME composition, dead keys and AltGr text are ignored.
2. A binding whose action has a page handler runs the handler and consumes the
   event.
3. A binding without a page handler, made only of strokes native could not
   see, is forwarded: `panel.forward_key {strokes: ["q"], sequence: false}`.
   Native matches the strokes in this panel's context, runs the action and
   replies `{handled, action?}`. Accelerators without a page handler are left
   alone: native already had them.
4. Chords whose strokes reach the page (`g g`, `] f`) are tracked here: 1.5 s
   window, Escape or a focus change cancels, key repeat does not complete a
   chord, an unmatched second stroke is swallowed. If the page binds a stroke
   both alone and as a chord prefix, the chord wins.
5. When native consumed a chord prefix itself (Ctrl+B of `ctrl+b c`), it posts
   `panel.key_sequence {active: true, timeout_ms}`; the next non-accelerator
   stroke is forwarded with `sequence: true`. `{active: false}` ends the state.
6. If native answers `panel.forward_key` with `method_not_found`, `forbidden` or
   `not_supported`, forwarding is switched off and those keys behave normally.

## Strings (`strings.js`)

`tr(key, englishDefault, params?)` mirrors native `ui/strings.zig`. Until
localization lands (W7) no catalogs are registered and the default is returned.
`{name}` placeholders are filled from `params`. `addStrings(locale, table)` and
`setLocale(locale)` are the W7 hooks (lookup tries `de-at`, then `de`).
`applyStrings(root?)` translates static markup: `data-i18n="key"` replaces an
element's text (its current text is the default; use it on leaf elements) and
`data-i18n-attr="title:key1; aria-label:key2"` replaces attributes (title, alt,
label, placeholder and the aria-label family only).

## Native contract checklist (W1-6 `web/bridge.zig`, `web/theme.zig`, input router)

Beyond ADR-6.5 the shared assets rely on:

1. `panel.forward_key {strokes: [string] (1 or 2), sequence: bool}` →
   `{handled: bool, action?: string}`: match the canonical strokes through the
   KeyRouter in the sending panel's context; with `sequence: true`, continue the
   pending chord. The page can be compromised (it may render untrusted
   content), so treat the strokes as untrusted input: match only bindings whose
   when-clause holds for this panel, and reject a request unless at least one
   stroke is one WebView2 cannot report through `AcceleratorKeyPressed`: no
   Ctrl, Alt or Win and a letter, digit, punctuation, `enter`, `tab`, `space` or
   `backspace` key, or any `mouse4`/`mouse5` stroke. The page never forwards
   anything else.
2. Event `panel.key_sequence {active: bool, timeout_ms?: number}` to the focused
   panel when a chord prefix from its `AcceleratorKeyPressed` was consumed, and
   `{active: false}` when the sequence ends.
3. Optional event `keymap` with a new keymap after shortcut changes.
4. `panel.init.keymap` in the shape above, filtered to this panel's context.
5. Theme payload keys as listed; `font_size_px` in CSS px.
6. `panel.ready` gets a reply, and `panel.init` is posted only after
   `panel.ready`. Reset key capture when the page navigates or reloads.
7. Read page messages with `get_WebMessageAsJson` (pages post objects).
