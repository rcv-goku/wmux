# `src/web/settings`: Settings window

PanelKind `settings` (ARCHITECTURE ADR-5.8, ADR-6.11), hosted in the
top-level `PanelHostWindow`, entry
`https://settings.wmux.example/settings/index.html`. Renders the settings form
generically from the spec registry's JSON Schema, plus hand-built pages for
Themes, Keyboard Shortcuts, wmux.json and Reset.

Covers: `persistence-settings-window`, `persistence-settings-app-group`,
`persistence-settings-terminal-presentation`,
`persistence-settings-notifications-group`,
`persistence-settings-sidebar-group`, `persistence-settings-browser-group`,
`persistence-settings-shortcuts-config`,
`persistence-settings-keyboard-shortcuts-section`,
`persistence-settings-reset-all`, `persistence-settings-themes-section`,
`core-shortcuts-settings-ui` (page side; the native side is described below).
The `*-group` entries are covered as "every key round-trips through a typed
Settings row": their keys come from the spec registry, not from this page.

| File | Purpose |
|---|---|
| `index.html` | page shell: nav with search, content area, status line, confirmation dialog |
| `settings.js` | entry module: theme sync, starts the app |
| `app.js` | the application: bridge, loading, nav, search, rows, sources, reset, events |
| `sections.js` | section ids, titles, search keywords, `settings open <target>` aliases |
| `schema.js` | schema -> fields, control kinds, validation, input parsing, search helpers (pure) |
| `effective.js` | `get_effective` normalization and row state: source, read-only, reset, modified (pure) |
| `controls.js` | typed controls: switch, select, number, text/path, color, list, key-value, JSON, strokes recorder |
| `shortcuts.js` | shortcut list normalization, display, validation, conflicts, search (pure) |
| `shortcuts-view.js` | Keyboard Shortcuts page: recorder, unbind/restore, reset, presets, find by keys |
| `themes.js` | theme values (`light:X,dark:Y`), gallery grouping, pick rules (pure) |
| `themes-view.js` | terminal theme gallery: swatches, search, Revert, Open in Terminal |
| `strings.js` | user-visible strings (`tr()` keys) |
| `settings.css` | layout on the `--wmux-*` tokens |

No third-party libraries: the page never renders HTML from data (all text is
set with `textContent`), so DOMPurify is not needed and the CSP adds
`require-trusted-types-for 'script'; trusted-types 'none'`.

## Native contract

Names follow ADR-5.8 and Appendix B (`wmux.settings.schema`,
`.get_effective`, `.set`, `.unset`; `wmux.shortcuts.list`, `.validate`,
`.set`). Methods and events ADR-5.8 does not name live under the panel's own
namespace `wmux.settings.*` so one allowlist entry (`wmux.settings.*`,
`wmux.shortcuts.*`) covers the kind. Pages never see policy or file internals
beyond what these replies contain.

### `panel.init`

| Key | Used for |
|---|---|
| `params.target` | section to open: a raw section id (`keyboardShortcuts`) or a cmux CLI alias (`shortcuts`, `keys`, `appearance`, `json`, ...; see `sections.js`). `settings.open {target}` from the CLI creates or focuses the window with this |
| `params.query` | optional: open with this search query |
| `state.section` | last section (from `panel.state_changed`) when restored |

A target that names no section keeps the current section (for `params.target`:
the restored `state.section`, else the first section) and says why:
Windows-omitted targets (`account`, `devices`, `networking`, ...) show
"“x” is not available on Windows.", anything else "Unknown settings section
“x”." A restored `state.section` that no longer exists is ignored quietly.

### Methods called by the page

| Method | Params -> result | Notes |
|---|---|---|
| `wmux.settings.schema` | `{}` -> `{schema, docs_url?}` or the schema itself | the generated JSON Schema (`docs/wmux/schema/wmux.schema.json` shape) with the `x-wmux-*` hints of `schema_dump.zig`. Root `$schema`, `schemaVersion` and `packs` are not rows |
| `wmux.settings.get_effective` | `{}` -> `{values: {"<path>": {value, source, locked?, error?}}, files?: {wmux, cmux}}` | `source` as in `config get --json`: `default`, `ghostty`, `cmux.json`, `wmux.json`, `project`, `policy`. `locked: true` (or `source: "policy"`) makes the row read-only. `error` is shown on the row (e.g. a type error that fell back to a lower layer). A list `[{path, value, source, ...}]` is accepted too |
| `wmux.settings.set` | `{path, value}` -> `{value, source, locked?}` | writes `wmux.json` through the lossless editor. Errors use the ADR-3.5 codes (no new ones), for example `invalid_params` for a bad value or `permission_denied` for a policy-locked key; the page shows their `message` on the row. Without `source` in the reply the page refetches `get_effective` |
| `wmux.settings.unset` | `{path}` -> `{value, source, ...}` | per-key Reset: removes the key from `wmux.json`; the reply is the next lower layer. Also used with `shortcuts.bindings.<id>` for per-action shortcut reset and by the Reset Default Shortcuts fallback. Everything after `shortcuts.bindings.` is one key, the action id, and ids may contain dots (`wmux.selectLayout.tiled`): native removes the segments `["shortcuts", "bindings", <id>]` (`json_edit.removePath`) and must not split that path on every `.` |
| `wmux.settings.reset_all` | `{}` -> `{}` | Reset All Settings: remove every setting the Settings window can write from `wmux.json` (keep `$schema`, `packs` and unknown keys); `cmux.json`, project and policy values stay. If native answers `method_not_found`/`not_supported`, the page unsets each `wmux.json` row instead |
| `wmux.settings.open_file` | `{file: "wmux" \| "cmux"}` -> `{}` | open the file in the default editor (creates `wmux.json` if missing) |
| `wmux.settings.open_docs` | `{topic: "settings" \| "shortcut-chords"}` -> `{}` | open the docs; on `method_not_found`, `not_supported` or `forbidden` the page falls back to `panel.open_external {url: docs_url}` when the schema reply carried one |
| `wmux.shortcuts.list` | `{}` -> `{actions: [...], presets?: [...], preset?}` | action: `{id, title, category, keys, default_keys, when?, when_label?, source, locked?, numbered?, bare_ok?, availability?}`. `keys` is an array of bindings; a binding is a stroke string, a chord string `"ctrl+b c"` or a nested chord array `["ctrl+b", "c"]` (ADR-8.3 Windows grammar). `source` as above. `category` is an `actions_catalog.zig` category; `viewer` (or `bare_ok`) allows bare keys. presets: `{name, title, description?, warning?}` from `keymap_presets.zig` (`cmux` is the default keymap); the page has a built-in fallback list |
| `wmux.shortcuts.validate` | `{id, keys: ["<binding>"]}` -> `{ok, errors?: [msg], warnings?: [msg], conflicts?: [{id, title?, keys}]}` | runs after the page's own checks; conflicts become "This shortcut conflicts with <action> (<keys>)" and block saving; warnings are shown. `method_not_found` or `not_supported` skips it |
| `wmux.shortcuts.set` | `{id, keys: ["<binding>"...]}` -> `{action?}` | write `shortcuts.bindings.<id>` in `wmux.json`; `keys: []` writes `null` (unbind). An `action` in the reply replaces the row |
| `wmux.settings.reset_shortcuts` | `{}` -> `{}` | Reset Default Shortcuts: remove every `shortcuts.bindings.<id>` from `wmux.json` (cmux.json and policy bindings are unaffected). Fallback: `wmux.settings.unset` per `wmux.json` row |
| `wmux.settings.apply_preset` | `{name}` -> `{changes: [{id, title?, old, new}], kept: [id \| {id, title}], warnings: [msg], notes: [msg]}` | apply `keymap_presets.plan` (writes only the differences). The page shows `<action>: <old> -> <new>`, `Kept your own shortcut for X.`, warnings (Windows-reserved collisions) and notes |
| `wmux.settings.list_themes` | `{}` -> `{themes: [{name, scheme?, background, foreground, palette?}], current}` | swatches parsed from the theme files (palette 0-15). `current` is the Ghostty `theme` value (`"Nord"` or `"light:A,dark:B"`), or null for Ghostty default colors |
| `wmux.settings.set_theme` | `{theme: "<value>" \| null}` -> `{}` | write the `theme` line of the wmux overlay `CONFIG\config.ghostty` (same writer as `wmux themes set`) and reload. `null` removes it |
| `wmux.settings.open_theme_picker` | `{}` -> `{}` | "Open in Terminal…": run `wmux themes` in a new tab |
| `panel.set_title`, `panel.state_changed`, `panel.key_capture`, `panel.open_external` | shared | title "Settings"; `{v: 1, section}`; recorder capture (via `keys.startCapture()`); docs fallback |

### Events pushed by native

Bridge events native posts to this panel (`{"v": 1, "event", "payload"}`),
not `cmux.event` frames. Only `wmux.settings.changed` is also an
`events.stream` event: `wmux_proto/events_catalog.zig` declares it for the
settings watcher with the payload key `changed_keys`. The other names are
panel-only.

| Event | Payload | Effect |
|---|---|---|
| `wmux.settings.navigate` | `{target}` | `wmux settings <target>` while the window is open: show that section |
| `wmux.settings.changed` | `{changed_keys?: ["<path>"], values?}` | after a reload (file watcher, CLI `config set`). `changed_keys` is the catalog payload; `values` (same shape as `get_effective`) is an optional extension for this panel. The page merges `values` when present, else refetches `get_effective` |
| `wmux.settings.schema_changed` | `{}` | refetch the schema and re-render |
| `wmux.settings.shortcuts_changed` | `{}` | refetch `wmux.shortcuts.list` |
| `wmux.settings.themes_changed` | `{}` | refetch `wmux.settings.list_themes` |
| `theme` | shared | handled by `_shared/theme.js` |

## Behavior notes

- **Sections.** `app themes terminal textBox sidebarAppearance automation
  browser browserImport globalHotkey keyboardShortcuts workspaceColors
  settingsJSON reset windows`; schema sections outside this list are appended.
  Rows follow schema order within a section.
- **Controls** (from `type`, `enum`, `pattern`, `x-wmux-kind`): boolean ->
  switch; enum -> select (an out-of-enum file value is shown but cannot be
  chosen again); integer/number -> number input with min/max/step; string ->
  text (pattern checked); `path` -> monospace text; color pattern -> swatch +
  `#RRGGBB[AA]` text (alpha kept; Clear when nullable); string array -> one
  entry per line; object -> key-value rows when every value is a scalar
  (`true`, `12` and `null` cells are JSON, other text is a string), else a
  JSON editor; `strokes` -> text plus a one-stroke recorder; anything else ->
  JSON editor. Values are validated before `wmux.settings.set`; native
  validates again. A reload never overwrites the control being edited
  unless that key's value changed. Input that fails the page's checks stays
  on screen next to its message. A value native rejects is replaced by the
  stored one. Object settings merge key by key across layers
  (`resolve.zig`), so an object row shows the merged value and saving writes
  all of it to `wmux.json`. A key that comes from a lower layer cannot be
  removed from this row. `shortcuts.bindings` is never a generic row; the
  shortcut editor owns it.
- **Sources.** A badge names the source when it is not the default;
  "Modified" when the value differs from the default; "Restart to apply" for
  `x-wmux-apply: restart`. Policy rows: "Managed by your organization",
  read-only. `cmux.json` rows: "Set in cmux.json", read-only until "Override
  in wmux.json" (wmux.json beats cmux.json, ADR-5.1). Project values show a
  note; project-only keys (`x-cmux-scopes: ["project"]`) are read-only here
  because the window writes the global `wmux.json`. Reset appears only for `wmux.json` values.
- **Search.** Tokens (NFKC, case-insensitive, all must match) over titles,
  descriptions, key paths, `x-wmux-keywords`, enum values and the section's
  title and keywords (`scrollback` finds the Terminal rows). Results are
  grouped by section with `<mark>` highlights; the nav shows match counts and
  dims sections without matches. Ctrl+F focuses the field, Escape clears it.
  A nav click, a result's section link or `wmux.settings.navigate` ends the
  search and shows the section.
- **Shortcuts.** Click a binding to record one stroke. Escape, a click or
  focus move outside the button, leaving the window or a re-render (deep
  link, schema change) cancels; a recorder never keeps capturing keys for a
  row that is gone (same for `strokes` rows). Checks: a modifier is required
  except for F-keys, mouse buttons and viewer actions ("Shortcuts must
  include Ctrl, Alt or Shift"); Shift alone only with keys that type no text,
  because the KeyRouter never matches Shift+<letter, digit, punctuation or
  space> (ADR-8.2; "Shift+A types text; add Ctrl or Alt.");
  Win and Alt+Tab / Ctrl+Esc / Ctrl+Shift+Esc / Ctrl+Alt+Delete / Alt+Esc are
  "reserved by Windows"; Alt+Space, Alt+F4, Ctrl+Alt+Tab and F1 warn;
  numbered actions need 1-9 and store digit 1; conflicts with an action in an
  overlapping context (or a chord prefix) block saving, where a numbered
  action's key counts for its whole 1-9 family (`ctrl+shift+1` also holds
  Ctrl+Shift+5; find by keys lists it too). Chords are edited in
  wmux.json ("Shortcut Chords" help). Unbind (X) turns into Restore. The
  Pane Resize Step row (`app.paneResizeStepPixels`) heads the page whatever
  section its spec names, and is not repeated among the section's rows.
- **Themes.** Picking a theme replaces the light or dark half by its scheme
  (a single theme is used for both until the other scheme is picked). Revert
  restores the value from when the gallery was loaded.
- **Keyboard.** Arrow keys, Home and End move through the nav. The recorder
  uses `keys.startCapture()` (`panel.key_capture {on}`) so native's KeyRouter
  skips the panel while recording. Views re-render after changes; focus stays
  on the same control (the activated nav item, the shortcut row's button,
  with X and Restore standing in for each other, the picked theme, Reset
  Default Shortcuts), and a search-result link moves focus to the section
  heading. Shortcut buttons name their action and current binding for screen
  readers.

## CSP

```
default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; font-src 'self'; frame-src 'none'; worker-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; require-trusted-types-for 'script'; trusted-types 'none'
```

## Tests

`test/web-node/settings/*.test.mjs` (node:test + jsdom, mock
`window.chrome.webview`, fake native settings/shortcut/theme stores in
`helpers.mjs`; schema fixtures are the committed `wmux.schema.json` and the
`schema_dump.zig` golden file):

```sh
npm install --prefix ../.webtest --ignore-scripts jsdom@26
WMUX_WEB_TEST_DEPS=../.webtest node --test 'test/web-node/settings/*.test.mjs'
```
