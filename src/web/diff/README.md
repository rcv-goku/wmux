# `src/web/diff`: diff viewer panel

PanelKind `diff` (ARCHITECTURE ADR-6.11, owner W4-3), entry
`https://diff.wmux.example/diff/index.html`. Renders a unified diff (from
`cmux diff` / `wmux.diff.open`) with a changed-files tree, unified and split
views, word and syntax highlights, viewed tracking, a file filter and file
search, find in diff, persisted display preferences and review comments that
can be sent to an agent.

Covers (page side): `panels-diff-viewer-ui`, `panels-diff-viewer-preferences`,
`panels-diff-keyboard-navigation`, `panels-diff-find`,
`panels-diff-file-filter-viewed`, `panels-diff-large-generated-collapse`,
`panels-diff-review-comments`, `panels-diff-session-restore` (page state),
`agents-diff-comments-to-agent` and `panels-diff-comments-textbox-delivery`
(the comment records and their `submissionText`; the workspace pool, TextBox
chip and delivery are native).

| File | Purpose |
|---|---|
| `index.html` | page shell: toolbar, Options menu, file search, find bar, files sidebar, viewport, Comments panel |
| `diff.js` | entry module: imports highlight.js and DOMPurify, starts the app |
| `app.js` | the application: bridge, loading, rendering, viewed, filter, find, comments, keys, state |
| `parse.js` | unified diff parser (pure) |
| `words.js` | intra-line word diff (pure) |
| `files.js` | deferral (generated / large), tree, filter, fingerprints, whitespace and context transforms (pure) |
| `comments.js` | comment record, `submissionText`, re-anchoring (pure) |
| `prefs.js` | preference sanitizing and precedence (pure) |
| `find.js` | find-in-diff search (pure) |
| `keymap.js` | action ids, default bindings, scroll targets (pure) |
| `highlight.js` | highlight.js -> DOMPurify -> per-line fragments; range wrapping |
| `render.js` | file sections and unified / split tables |
| `strings.js` | user-visible strings (`tr()` keys; cmux labels) |
| `diff.css` | layout and diff colors on the `--wmux-*` tokens |

Libraries (already vendored, see `../_vendor/`): highlight.js 11.12.0 (core +
common languages, GitHub light/dark styles) and DOMPurify 3.4.17. No new
library was added; the parser, word diff and renderer are written here.

## Native contract

Names follow ADR-6.5. cmux names its viewer bridge calls (`comments.list`,
`comments.save`, `comments.delete`, `viewedFiles.list`, `viewedFiles.set`,
`viewedFiles.clear`, `viewerPrefs.*`); the page uses exactly those. Calls cmux
does not name live under the panel's own namespace `panel.diff.*` (handled by
the kind's `on_message`, like `panel.markdown.*`). Suggested allowlist for the
PanelKind: `comments.list`, `comments.save`, `comments.delete`,
`viewedFiles.*`, `viewerPrefs.set` (`panel.*` is implicit).

Native identifies the panel by its controller, so none of these calls carry a
repository, source identity or workspace: native keys the comment store by the
canonical repo root of the panel's diff, the viewed store by (repo root, source
identity: `unstaged` | `staged` | `branch:<base>` | `patch:<path>` ...), and the
comment pool by the panel's workspace.

### `panel.init`

| Key | Used for |
|---|---|
| `params.title` | toolbar and tab title (`--title`); empty -> the load result's `title`, then "Untitled" |
| `params.patch` | patch text inline (small diffs) |
| `params.patch_url` | otherwise: a token URL, normally `https://d-<16hex>.wmux.example/...` served by `WebResourceRequested` (ADR-6.4). The page fetches it without credentials only when it starts with `https://<label>.wmux.example/` (so an `f-<16hex>` file host works too) and refuses any other URL; the same rule applies to a `patch_url` returned by `panel.diff.load` |
| (neither) | the page calls `panel.diff.load` |
| `params.layout` | `"unified"` / `"split"`: explicit `--layout`, beats persisted prefs and the setting |
| `params.prefs` | the stored `preferences.json` object (native reads it at open time; sanitized again here) |
| `params.font_size` | `--font-size` in pt (6..72); default 10 |
| `params.generated` | paths marked `linguist-generated` or `-diff` (`git check-attr`), deferred as "Generated file" |
| `params.apply_command` | optional: the text "Copy git apply command" copies (default below) |
| `params.find` | optional: open the find bar with this query |
| `settings` | `diffViewer.defaultLayout` (`unified` / `split`; flat dotted key or `{diffViewer: {defaultLayout}}`) |
| `state` | the last `panel.state_changed` state when restored (below) |
| `keymap` | effective bindings; replaces the defaults in `keymap.js` |

### Methods called by the page

| Method | Params -> result | Notes |
|---|---|---|
| `panel.diff.load` | `{refresh, context_lines, ignore_whitespace}` -> `{patch` or `patch_url, title?, generated?, apply_command?}` | initial load when `params` has no patch, and every Refresh (`refresh: true`). Native regenerates the diff for refreshes; it may honor `context_lines` (`git diff -U<n>`) and `ignore_whitespace` (`-w`), the page applies both itself anyway (changing either re-renders the current patch at once; a diff regenerated with them arrives with the next Refresh, and viewed marks survive it). If the method is unsupported, Refresh re-fetches `params.patch_url` |
| `viewedFiles.list` | `{}` -> `{files: [{path, fingerprint}]}` (or `{viewed: {path: fingerprint}}`) | at start and before each refresh |
| `viewedFiles.set` | `{path, fingerprint, viewed}` -> `{}` | Viewed checkbox / `v`. `fingerprint` = `"fp1:"` + 16 hex digits, computed in the page over the blob ids of the git `index` line (cut to 7 digits), the paths, the status and the modes, so a diff regenerated with other `context_lines` or `ignore_whitespace` keeps its marks; files without an index line (plain `diff -u`, pure renames and mode changes) hash their patch text. A stored fingerprint that differs shows "Changed since viewed" |
| `viewedFiles.clear` | `{}` -> `{}` | `app.clearViewed()` (not bound to UI; available to native through a command if wanted) |
| `viewerPrefs.set` | `{prefs: {layout, diffIndicators, wordWrap, wordDiffs, lineNumbers, showBackgrounds, expandUnchanged, ignoreWhitespace, contextLines}}` -> `{}` | after every preference change. Native whitelists keys and values again and writes `preferences.json` (`WMUX_DIFF_VIEWER_PREFS_PATH` / `CMUX_DIFF_VIEWER_PREFS_PATH`). `ignoreWhitespace` and `contextLines` are wmux additions |
| `comments.list` | `{}` -> `{comments: [record]}` (or a bare array) | at start; again on `panel.diff.comments_changed` without a payload |
| `comments.save` | `{comment: record}` -> `{comment?: record}` | create and edit (same `id`). The page fills every field, including `submissionText`; native stores atomically and adds unconsumed records to the workspace pool |
| `comments.delete` | `{id}` -> `{}` | |
| `panel.diff.send_comments` | `{ids: [..]}` -> `{consumed?: [{id, consumedAt}] \| [id]}` | "Send to agent": deliver these pending comments now (the TextBox pool path, or the `+comments send` fallback that pastes them into the agent terminal) and mark them consumed. Without `consumed` the page marks all `ids` |
| `panel.set_title` | `{title}` | |
| `panel.state_changed` | `{state}` | see "Session state" |
| `panel.clipboard_write` | `{text}` | Copy git apply command |

Errors `method_not_found`, `not_supported`, `forbidden` or `not_allowed` from
`viewedFiles.*` or `comments.list` switch that feature's native calls off
quietly, and the same codes from `viewerPrefs.set` are not logged: viewed
marks and preferences then last for the page's lifetime only, and no stored
comments are shown (other errors from these calls are logged).
`comments.save`, `comments.delete` and `panel.diff.send_comments` report every
error in the status bar (a failed save keeps the composer open), so adding
comments needs the native store. A failed initial `panel.diff.load` shows the
cmux error message; on Refresh the unsupported codes fall back to
`params.patch_url`, then `params.patch`.

Comment record (cmux schema): `{id, filePath, side: "additions" | "deletions",
startLine, endLine, endSide?, lineText, message, submissionText, consumedAt?,
createdAt, updatedAt}`. `id` is a UUID from `crypto.randomUUID()`; timestamps
are ISO 8601 strings; `lineText` is the text of lines `startLine..endLine` on
`side`, joined with `\n` (used for re-anchoring). `submissionText`:

````
Review comment on <filePath> line <n>|lines <a>-<b> (new|old version):

```diff
+<the commented lines with their diff prefix>
```

<message>
````

When the lines are no longer in the diff, a plain fenced excerpt of `lineText`
replaces the `diff` block. Fences grow when the excerpt contains backticks.

### Events pushed by native

| Event | Payload | Effect |
|---|---|---|
| `panel.diff.patch` | `{patch, title?, generated?, apply_command?}` | replace the diff (native-initiated refresh); choices and scroll position by file survive |
| `panel.diff.comments_changed` | `{comments?}` | the store changed (another viewer, TextBox consumption, chip dismissal) |
| `panel.diff.viewed_changed` | `{files?}` / `{viewed?}` | the viewed store changed |
| `panel.diff.command` | `{action}` | run a page action from the palette or a native shortcut: every `diffViewer*` id, `find`, `findNext`, `findPrevious`, `hideFind`, and the wmux-only `wmux.diffRefresh` |
| `panel.diff.find` | `{query}` | open the find bar pre-filled |
| `theme`, `keymap`, `panel.key_sequence` | shared | handled by `_shared/` |

Native forwards the find chords (Ctrl+F / F3 / Shift+F3 and Escape) for a
focused diff panel as `panel.diff.command` when its KeyRouter consumes them
(`isDiffViewerFindOwner` parity); otherwise the page's own bindings handle them.
An Escape that reaches the page closes its overlays even when the keymap has
no `hideFind` binding, so native does not need to evaluate `findVisible` for
the page's find bar.

### Session state (`panel.state_changed`)

`{v: 1, prefs: {...}, files_visible, top_file: "<path>", collapsed: [path, ...]
(at most 200), find: "<query>"}`, debounced 400 ms and flushed on `pagehide`.
The snapshot always fits the 64 KiB `panel.state_changed` cap: `collapsed`
stops at 32 KiB of encoded paths, and a `top_file` or `find` above 8 KiB is
left out (`null` / `""`).
On restore the viewer's own `prefs` win over everything else, the files
sidebar, collapsed files, find query and scroll position (by file) come back.
The diff itself is not in the state: native re-validates its manifest and
passes the patch again (`panels-diff-session-restore`).

## Behavior notes

- **Parser.** `git diff` / `format-patch` / `diff -u` input; extended headers
  (`old/new mode`, `new/deleted file mode`, `rename from/to`, `copy from/to`,
  `similarity index`, `index`), C-quoted paths (octal UTF-8 escapes), binary
  markers (`Binary files ... differ`, `GIT binary patch` payloads skipped),
  `\ No newline at end of file`, combined diffs (`diff --cc`, `@@@`, one prefix
  column per parent; line numbers are parent 1 and the result). Hunk line
  counts end a hunk, so format-patch signatures and commit text are ignored.
  Malformed hunks are logged and skipped, never fatal.
- **Views.** Unified (old and new numbers, one code column) and split (old
  left, new right, change blocks paired row by row). Combined diffs always
  render unified. Rename/copy headers show `old → new` and the similarity;
  mode changes show `Mode {old} → {new}`; binary files show "Binary file".
- **Highlights.** Syntax: each hunk side is highlighted as one block (so
  multi-line comments and strings stay correct), sanitized to `<span class>`
  by DOMPurify and split per line; sides over 100,000 characters stay plain.
  Words: deleted and added lines of a change block pair up in order and are
  diffed on word / whitespace / symbol tokens (Unicode aware); lines over 2000
  characters or pairs sharing under 25% of their text are not word-marked.
- **Deferral.** Lockfiles (`bun.lock`, `bun.lockb`, `package-lock.json`,
  `yarn.lock`, `pnpm-lock.yaml`, `Cargo.lock`, `Package.resolved`, `go.sum`,
  `Gemfile.lock`, `poetry.lock`, `uv.lock`) and `params.generated` paths show
  "Generated file"; files with >= 2,000 changed lines or >= 400 KiB of patch
  text show "Large diff". Both render on "Load diff" (or Expand all, a file
  search jump, or a find match).
- **Context and whitespace.** "Collapse unchanged context" (default) keeps
  `contextLines` (default 3) unchanged lines around changes, comments and the
  current find match; longer runs become "Show N unchanged lines" rows.
  "Expand unchanged context" shows everything the patch has. "Ignore
  whitespace" turns paired deleted/added lines that differ only in whitespace
  into context lines.
- **Viewed.** Checking Viewed (or `v` on the file at the top) collapses the
  file; the header progress reads "{viewed} of {total} files viewed" over all
  files (not only the filtered ones).
- **Filter.** Path terms (space-separated, all must match the path or old
  path, case-insensitive), a status subset (Added includes copies, Modified,
  Deleted, Renamed) and Hide viewed files hide tree rows and sections; "No
  files match the filter." with "Clear filter" when nothing is left.
- **File search.** `/` (or "Show file search") opens "Jump to file": fuzzy
  ranking (basename and contiguous matches first), arrows, Enter jumps.
- **Find.** Ctrl+F: case-insensitive literal search over the line text of both
  sides of every file (collapsed and deferred files included), up to 9,999
  matches ("n/m+" when capped). Enter / Shift+Enter or F3 / Shift+F3 cycle;
  the current match expands its file and gap and is scrolled to the middle.
  Escape closes the innermost overlay: comment composer, Options menu, file
  search, then find.
- **Keys.** Defaults from Appendix A.5 (`j`/`k`, Ctrl+D/U, Ctrl+N/P, Shift+G,
  `g g`, `/`, `] f`/`[ f`, `n`/`p` hunks, `v`), replaced by `panel.init.keymap`.
  Bare keys are ignored while a text field has focus (keys.js).
- **Comments.** Click a line number to select it, Shift+click another on the
  same side of the same hunk to extend the range (a Shift+click in another
  hunk starts a new selection: lines between hunks are not in the diff, so a
  comment could not anchor there), then the `+` button on a selected line ("Add
  comment") opens the composer ("Leave a comment", Comment / Cancel; Ctrl+Enter
  submits, Escape cancels). In split view the left column is the old version
  (`deletions`), the right the new one (`additions`); in unified view deleted
  lines are `deletions` and context/added lines `additions`. Saved comments
  render under their last line with Edit / Delete and in the Comments panel
  ("No comments yet"). On every load comments re-anchor: anchored, "Moved"
  (same text found nearby, nearest wins), "Outdated" (text gone) or "Not in
  this diff" (file absent); the last two only appear in the Comments panel.
  Sent comments show "Sent to agent" and leave the pending set.
- **Copy git apply command.** Copies a POSIX here-document
  (`git apply <<'WMUX_PATCH' ... WMUX_PATCH`; the delimiter never occurs as a
  patch line) unless native passes `apply_command` (e.g. a PowerShell form).
- **Theme.** Colors derive from the terminal palette (`--wmux-success`,
  `--wmux-danger`), the font is the terminal font, the size is
  `params.font_size` pt; highlight.js switches GitHub light/dark with the
  scheme. Narrow panes (< 760 px) move the secondary toolbar buttons into the
  Options menu. Windows contrast themes (forced colors) drop backgrounds, so
  there the +/- column is always shown, changed words are underlined and find
  hits and the line selection use system colors.
- **Accessibility.** The Options popover and the file list are plain buttons
  in a group and nested lists (Tab order), not ARIA menu / tree widgets.
  Buttons whose label names the action ("Hide files", "Enable word wrap")
  carry no pressed state; the file and search toggles report `aria-expanded`
  and the indicator choice `aria-pressed`.

## CSP

```
default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self' https://*.wmux.example; img-src 'self' data:; font-src 'self'; frame-src 'none'; worker-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'
```

`connect-src` allows the per-panel data host (`_shared/README.md`: partial
label wildcards such as `d-*.wmux.example` are not valid CSP). No
trusted-types directive: DOMPurify parses the highlight.js markup through an
HTML sink before returning DOM fragments. Patch text only ever reaches the DOM through
`textContent` or DOMPurify-sanitized `<span class>` trees.

## Tests

`test/web-node/diff/` (node:test + jsdom, mock `window.chrome.webview`):

```sh
npm install --prefix ../.webtest --ignore-scripts jsdom@26
WMUX_WEB_TEST_DEPS=../.webtest node --test 'test/web-node/diff/*.test.mjs'
```
