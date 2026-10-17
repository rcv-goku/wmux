# wmux → cmux parity: AUTHORITATIVE ARCHITECTURE

Status: **AUTHORITATIVE**. Supersedes `proposal-compat.md`, `proposal-native.md` and `proposal-delivery.md`.
Date: 2026-10-15. Baseline: wmux `master` @ `aa1f532` (Zig 0.15.2, hand-written Win32 apprt).
Scope: the 815 in-scope open features in `research/parity/matrix.csv` (scope `local-core` / `local-extended`, status `partial` / `missing`; 102 critical).

How to use this document:
- Every implementation agent reads §0, the ADR(s) for its area, §15 (Conventions) and its WP spec (`docs/arch/wp/<id>.md`, template in Appendix H). Then it reads the `inventory/`, `gaps/` and `verify/` entries for the feature ids its WP covers.
- **MUST / MUST NOT / SHOULD** are normative. Code sketches are binding for names, fields and signatures; bodies are illustrative.
- If this document and a WP spec disagree, this document wins unless the WP spec cites an approved CCR (§1.7). Changes to this document are made only by the lead architect, as a dated entry in Appendix F.
- W0-C copies this file into the repo as `docs/arch/ARCHITECTURE.md`; agents read it there.

---

## 0. Summary, glossary, ground rules

### 0.1 Decision summary

| ADR | Decision |
|---|---|
| 1 Modularization | Layered tree `app/ platform/ model/ ui/ input/ rpc/ settings/ web/ features/` under `src/apprt/win32/`, a std-only shared module `src/wmux_proto/` and a console CLI `src/wmux_cli/`. A feature registers by **declaring** things in its own `features/<id>/mod.zig`; comptime registries aggregate them from **pre-seeded frozen manifests** (no build-time codegen). Per-object feature state lives in pre-seeded `ext` structs. Wave 0 restructures before any feature work. |
| 2 Identity | Every window, workspace, group, pane and surface has an uppercase UUIDv4 and a never-reused per-kind ref (`window:N`, `workspace:N`, `workspace_group:N`, `pane:N`, `surface:N`; `tab:N` = surface alias). Both are persisted and adopted on restore; refs are reserved crash-safely. Indexes are positional and contextual. One resolver accepts all three forms; legacy integer ids are adapted. |
| 3 Control plane | Thread-per-connection named-pipe server on `\\.\pipe\wmux-<channel>-<sidhash8>-s<session>`, plus an always-on launch pipe (single instance per channel) and the legacy `wmux-ipc-<pid>` pipe for one release. cmux v2 envelope, error codes and method names; lanes `pipe` / `worker` / `ui`; 10 s UI deadlines; admission and rate limits; deferred replies bound to a connection generation. Adapters for legacy wmux JSON and cmux text-v1. Access modes use cmux names, default `cmuxOnly` = job membership ∨ creation-time-verified ancestry ∨ `_cmux_capability_v1` token. Protected `CMUX_*`/`WMUX_*` terminal environment. cmux `events.stream`. |
| 4 CLI | One slim console exe built as `cmux.exe`, installed in `INSTALL\cli\` with a byte copy `wmux.com` and LF sh launchers `cmux`/`wmux`. The GUI `wmux.exe` is never on PATH and relays CLI-shaped argv to `cli\cmux.exe`. **The installer never touches PATH** (existing repo rule): PATH is prepended inside wmux terminals, and an opt-in `cmux install-cli` (W7) drops forwarders into a directory already on PATH. cmux grammar, help topics and global options; legacy `+verbs` mapped; agent shims by argv[0]. |
| 5 Configuration | Precedence: defaults < explicitly-set legacy Ghostty keys < `~/.config/cmux/cmux.json` < `~/.config/wmux/wmux.json` < project files < Group Policy. JSONC with cmux key paths; specs declared per feature in `wmux_proto`; lossless edits; live reload; offline `config` CLI. Ghostty config keeps terminal settings plus a wmux overlay. Settings window = WebView2 web panel. |
| 6 Web panels | One `WebPanel` tab-content kind, four host placements (tab, right sidebar, popup, top-level window), one shared WebView2 environment with an isolated `wmux-ui` profile, per-app virtual hosts `https://<app>.wmux.example/`, vanilla ES modules with vendored libraries (no JS toolchain in the build), a JSON bridge speaking the v2 envelope under a per-kind allowlist, theme sync, lazy controllers, session snapshot hooks. |
| 7 Notifications | Pure store with cmux replacement and unread semantics; heap OSC payloads, per-surface coalescing and a bounded ingress FIFO; policy pipeline; WinRT toasts under a registry-registered AUMID with `wmux:` protocol activation (COM activator only for inline Reply); one persistent tray icon as fallback; self-played sounds; cmux focus suppression; History withdraw. |
| 8 Keyboard | Complete actions catalog keyed by cmux action ids (pure data) + feature handlers + an app-level KeyRouter that runs before Ghostty bindings and before WebView2 pages (when-clauses, chords, "text always wins" AltGr rule). Windows default keymap (Appendix A) never claims terminal control keys. Ghostty interop through one `wmux:<id>` binding action. |
| 9 Session | v3 snapshot of all windows (nested; `ext` per object), autosave every 8 s on structural change, full save on quit/logoff/update, restore on launch with a crash-loop guard, one-time v2 migration, terminal-side scrollback replay before the shell starts, agent resume typed after the first prompt. |
| 10 Agents | `cmux hooks <agent> <event>` in the slim CLI: the CLI writes the per-agent store under a file lock, sends a fire-and-forget `wmux.agent.hook` (200 ms connect) or spools. Catalog-driven installers with Windows paths. App-side lifecycle state machine feeds sidebar, notifications, feed and resume. `claude.exe`/`codex.exe` wrappers; `tmux.exe` compat shim and team launchers run teammates as structured argv through Git Bash or WSL. |
| 11 Sidebar | Left sidebar = its own child HWND drawn with Direct2D/DirectWrite from a pure row model (variable heights, virtualized scrolling, feature row contributors, keyboard focus mode, tooltips, per-monitor DPI). Right sidebar = mode host (web panels, Dock). Tab bars stay GDI until W5. |
| 12 Testing | `unit: <feature>: …` tests over pure logic; a fast no-Ghostty test step; a PowerShell 7 harness that launches isolated hidden instances (unique channel/state/config, fake clipboard, toast sink, never foreground) and drives them over pipe and CLI; JUnit/JSON output; coverage against `matrix.csv`; CI with Mesa llvmpipe. |
| 13 Remote | One `ssh.exe` carrier per resolved route (Windows has no ControlMaster) running a clean-room Zig `wmuxd-remote`; local ConPTY attach helper; reconnect state machine; HMAC CLI relay with a deny-by-default allowlist; browser egress through a per-route WebView2 environment and a PID-admitted local proxy; ssh-tmux mirror on Ghostty's control parser with session→group, window→workspace, pane→pane. |
| 14 Phasing | W0 restructure (single core lane; harness, tooling and spikes in parallel) → W1 eight foundations → W2 core parity → W3 agents and desktop delivery → W4 panels, settings, organization → W5 extended local → W6 remote → W7 polish. One merge at a time behind gates; one owner per hot file per wave. |

### 0.2 Glossary (names used in code after Wave 0)

| cmux concept | wmux today | wmux after W0 (type, file) | Wire handle |
|---|---|---|---|
| window | `Window` (`Window.zig`) | `Window` (`ui/Window.zig`) + model fields | `window_id`, `window:N` |
| workspace (sidebar row) | `Workspace` value in `Window.workspaces[16]` | `*Workspace` heap object (`model/Workspace.zig`) | `workspace_id`, `workspace:N` |
| workspace group | none | `*Group` (`model/Group.zig`) | `group_id`, `workspace_group:N` |
| pane (split leaf with a tab bar) | `PaneContainer` | `*Pane` (`model/Pane.zig`) | `pane_id`, `pane:N` |
| surface (tab in a pane) | slot index into PaneContainer parallel arrays + `Pane` | `*Tab` (`model/Tab.zig`) | `surface_id`, `surface:N` (`tab:N` alias) |
| panel (surface content) | `Pane.Content{terminal, browser}` | `TabContent` union (`model/TabContent.zig`): `terminal *Surface`, `browser *BrowserPane`, `web *WebPanel`, `placeholder` | `panel_id` == `surface_id` |
| terminal surface | `Surface` (apprt) | unchanged: `src/apprt/win32/Surface.zig` (Ghostty apprt contract) | n/a |

`CMUX_TAB_ID` keeps cmux's legacy meaning (the **workspace** UUID; verified in cmux sources). `tab:N` in text output is an alias of `surface:N`.

### 0.3 Ground rules (apply to every work package)

- **G1 Clean room.** cmux is GPL-3.0-or-later; wmux is MIT. Copy **interface facts only**: command, flag, method and event names; param/result keys; env var names; error codes and the short error strings scripts match on; file and JSON key names; action ids; documented output formats. NEVER copy cmux source, scripts, HTML/CSS/JS, schemas, tests or doc prose, and NEVER execute anything from the cmux clone. Third-party web libraries must be MIT/BSD/Apache-2.0/ISC and vendored with their LICENSE.
- **G2 Name rule.** If cmux defines a name (CLI command/flag, v2 method in its capabilities list, event, env var, `cmux.json` key, action id), wmux implements it with cmux semantics or does not claim it. wmux-only names live under `wmux.*` (methods `wmux.sidebar.status.set`, events `wmux.*`, action ids `wmux.toggleQuickTerminal`, settings under the `wmux` key of `wmux.json`), including v2 equivalents of commands cmux exposes only over its v1 text protocol. Cloud, account, mobile and macOS-only families return `not_supported` (Appendix B).
- **G3 UI-thread ownership.** Model objects, HWND state and WebView2 objects are touched only on the UI thread. Other threads post `app.tasks` closures with owned payloads. The UI thread never does blocking file, network or process I/O, except the synchronous final save inside `WM_ENDSESSION`.
- **G4 No focus stealing.** Socket, CLI, automation and test paths never activate a window or steal OS foreground. Only `focus_intent` methods change in-app selection, and only `app/foreground.zig` may call activation APIs (ADR-3.11).
- **G5 Reply exactly once.** Every RPC handler completes its `Ctx` exactly once (`ok`, `fail`, or `deferReply` + one completion). Debug builds assert it.
- **G6 Text safety.** No new fixed-size text buffers in model or protocol code; strings are heap-owned with explicit byte caps truncated on code-point boundaries (`wmux_proto/utf8.zig: truncateUtf8`). Zig 0.15 `utf8ToUtf16Le`/`utf16LeToUtf8` do not bounds-check in ReleaseFast: use the `*Alloc` variants or cap first.
- **G7 No model caps.** `MAX_WORKSPACES`, `MAX_TABS` and similar caps are removed. Only I/O buffers and persistence (ADR-9 limits) are bounded.
- **G8 Extension points only.** New features MUST NOT add new legacy `+verbs`, new wmux-v1 JSON `cmd`s, new Ghostty `Binding.Action` variants, new Ghostty `Config.zig` keys, new `WM_APP+N` ids or new hand-numbered timer/menu ids. Use the registries, `ext` state, events, `app.tasks`, `app.timers` and the menu builder.
- **G9 Proof.** Every user-visible feature ships pure-logic unit tests and an e2e suite that encodes the automatable acceptance lines of its inventory entries (§15.8).
- **G10 Deviations are explicit.** Any Windows behavior that differs from cmux is listed in Appendix E (a doc change by the lead architect, requested in the WP spec).

### 0.4 Zig 0.15.2 notes every agent needs

- `std.ArrayList(T)` is unmanaged (`.empty`, `list.append(gpa, x)`); `std.ArrayListUnmanaged` is an alias.
- I/O is `std.Io.Writer`/`std.Io.Reader`. JSON: `var aw: std.Io.Writer.Allocating = .init(gpa); try std.json.Stringify.value(v, .{}, &aw.writer);` (pattern already used in `App.zig`). Custom `format` methods take `(self, w: *std.Io.Writer) !void` and are invoked with `{f}`.
- `usingnamespace` does not exist. Methods cannot be spread across files; moved functions take `*Window`/`*App` explicitly. During W0, `pub const f = @import("x.zig").f;` aliases inside `Window`/`App` keep existing call sites compiling; new code MUST NOT add aliases.
- A source file belongs to exactly one module per compilation. `src/wmux_proto/**` is imported **only** as `@import("wmux_proto")`; never relative-import into it, and never relative-import out of it. The same holds for `src/wmux_cli/**`.
- `std.StaticStringMap(V).initComptime(kvs)` for comptime tables. Registries perform an explicit comptime duplicate check (`@compileError` naming the duplicate) and set `@setEvalBranchQuota(1_000_000)` locally.
- Run `zig fmt` on every changed file.

---

## ADR-1. Codebase modularization for parallel agents

### Decision

1. Restructure `src/apprt/win32/` into layers plus one directory per feature, add the shared pure module `src/wmux_proto/` and the CLI executable `src/wmux_cli/`.
2. Every cross-cutting list is a **comptime aggregation over a frozen manifest** that Wave 0 pre-populates with every planned module. Features add behavior by filling files they own. Nobody edits a shared enum, switch or list after Wave 0.
3. Per-object feature state uses pre-seeded `ext` structs with one zero-size field per feature, so model structs are never edited for features.
4. Exhaustive-switch hot spots get one-time generic entry points: `WM_APP_TASK`, a timer service, a dynamic-ID menu builder, window/app message hooks, a fully delegating `perform_action.zig`, and a single Ghostty binding action `wmux:<id>` (pre-wired in W0-A3, used from W1-5 on).

### Rationale

The gap analyses name `App.zig` in 400 of 894 items, `Window.zig` in 269, `Config.zig` in 192, `ipc.zig` in 116 and `Binding.zig` in 78; one new keybind edits seven files today, an IPC verb three shared switches, a per-tab field seven creation sites. Git never conflicts on files that do not exist yet. Build-time codegen (proposal-native) was rejected: configure-time writes into the source tree race with parallel builds and editor tooling, and generated files are invisible to review. `@Type`-reified ext structs (proposal-delivery) were rejected in favor of explicit pre-seeded fields: same effect, no comptime reification failure modes.

### 1.1 Target layout (exact)

```
src/
  wmux_proto/                      named module "wmux_proto"; std-only; shared by app, CLI and (W6) remote daemon
    proto.zig                      root: re-exports everything below
    uuid.zig handles.zig selectors.zig envelope.zig errors.zig idformat.zig
    paths.zig pipe_name.zig env_names.zig channel.zig
    jsonc.zig json_edit.zig when.zig strokes.zig utf8.zig shell_quote.zig win_argv.zig
    actions_catalog.zig            COMPLETE action catalog (Appendix A), pure data      [shared-appendable]
    events_catalog.zig             COMPLETE event catalog (cmux docs/events.md + wmux.*)  [shared-appendable]
    keymap_presets.zig             preset diffs (windows-terminal, tmux, linux-ghostty, wmux-classic)
    settings/ spec.zig resolve.zig validate.zig schema_dump.zig cmux_known_keys.zig
              specs_manifest.zig   [frozen]   specs/<feature-id>.zig  (one per feature)
    remote/                        (W6) daemon wire types
  wmux_cli/                        executable "cmux" (console subsystem); installed as cli\cmux.exe + cli\wmux.com
    main.zig args.zig client.zig discovery.zig output.zig help.zig targets.zig focus_default.zig
    launch.zig relay.zig win.zig (own minimal externs)
    commands/manifest.zig [frozen]  commands/<family>.zig
    agents/manifest.zig [frozen]    agents/<agent>.zig      hooks/  wrappers/  installers/  tmux/
    help/<command>.txt  scripts/{cmux,wmux} (LF sh launchers)
  apprt/win32/
    App.zig                        lifecycle, class registration, message loop, performAction → app/perform_action.zig  [frozen]
    Surface.zig                    terminal surface (apprt contract file; owned per WP spec)
    app/       tasks.zig timers.zig runtime_env.zig paths.zig foreground.zig clipboard.zig modal.zig
               message_loop.zig perform_action.zig hooks.zig broadcast_window.zig single_instance.zig (W1-1)
    platform/  win32.zig (moved; append-only, one marked section per WP) com.zig hstring.zig job.zig dpapi.zig
               taskbar.zig d2d.zig dwrite.zig webview2.zig winrt/*.zig uia/*.zig shell.zig
    model/     ids.zig registry.zig Workspace.zig Group.zig Pane.zig Tab.zig TabContent.zig tree.zig layout.zig
               focus.zig events.zig ops/{window,workspace,group,pane,surface,move}.zig logic/
               (the window's model fields live in ui/Window.zig)
    ui/        Window.zig [frozen]  chrome.zig gfx/ sidebar/ right_sidebar/ tabbar/ palette/ find/ overlays/
               menus.zig contrib.zig rename.zig placement.zig placement_state.zig dnd.zig dpi.zig theme.zig icons.zig
               popup.zig notice.zig strings.zig logic/
    input/     router.zig context.zig chord.zig altgr.zig actions.zig ghostty_interop.zig logic/
    rpc/       types.zig [frozen] registry.zig [frozen] dispatch.zig router.zig reply.zig stream.zig auth.zig
               server/{PipeServer,Connection,admission,ratelimit,launch_pipe,legacy_pipe}.zig
               compat/{legacy_json,text_v1}.zig  logic/
    settings/  loader.zig snapshot.zig watcher.zig ghostty_layer.zig policy.zig api.zig logic/
    web/       env.zig WebPanel.zig WebHost.zig bridge.zig PanelKind.zig assets.zig theme.zig file_hosts.zig
               BrowserPane.zig cdp/*.zig logic/
    features/  manifest.zig [frozen, merge=union]  ext.zig [frozen, merge=union]  lifecycle.zig [frozen]
               <feature-id>/ mod.zig state.zig [actions.zig rpc.zig contrib.zig panels.zig api.zig legacy.zig
                             text_verbs.zig sidebar.zig logic/ ...]
    fast_tests.zig                 root of `zig build test-fast` [frozen]
    test_index.zig                 pulled from App.zig's test block [frozen]
  web/                             web panel assets (ADR-6): _shared/ _vendor/<lib>@<ver>/ <app>/
  remote/daemon/                   (W6) wmuxd-remote
test/e2e/                          WmuxTest.psm1, run.ps1, coverage.ps1, suites/<area>/*.e2e.ps1
docs/arch/                         ARCHITECTURE.md, wp/<id>.md, ccr/<wp>-<n>.md, spikes/<name>.md
docs/wmux/                         features/<id>.md, cli/<family>.md, schema/wmux.schema.json
changes/                           changelog fragments <wp-id>.md
scripts/                           new-worktree.ps1 gate.ps1 check-ownership.ps1 check-manifest.ps1 coverage.ps1
```

### 1.2 Module dependency rules

- `wmux_proto`: std only. OS-specific files (`paths.zig`, `pipe_name.zig`) guard on `builtin.os.tag`.
- `**/logic/*.zig`: std, `wmux_proto` and sibling `logic/` files only. No Win32, no `App`, no model pointers. These files run in `zig build test-fast`.
- `platform/*`: Win32/COM/WinRT/WebView2/D2D bindings only. No model, ui or feature imports.
- `model/*`: may import `platform`, `features/ext.zig`, `wmux_proto`. Not `ui`, `rpc`, `web` or feature internals.
- `features/<a>/**` MUST NOT import internals of `features/<b>`. Cross-feature calls go through `features/<b>/api.zig` or model events.
- `ui/`, `input/`, `rpc/`, `web/`, `settings/` are layers: features use their public types; layers never import feature internals except through registries.

### 1.3 Feature module contract

`features/<id>/mod.zig` is the only file the manifest imports. All declarations are optional:

```zig
pub const id = "notifications";              // == dir name == ext field name == session ext key == specs file name
pub const rpc_methods = @import("rpc.zig").methods;            // []const rpc.Method        (ADR-3.6)
pub const legacy_commands = @import("legacy.zig").commands;    // []const rpc.LegacyCommand (wmux-v1 JSON; W0 moves only)
pub const text_verbs = @import("text_verbs.zig").verbs;        // []const rpc.TextVerb      (cmux v1 text)
pub const action_handlers = @import("actions.zig").handlers;   // []const input.ActionHandler (ADR-8)
pub const menu_items = @import("contrib.zig").menu_items;      // []const ui.MenuItem
pub const palette_providers = @import("contrib.zig").palette;  // []const ui.PaletteProvider
pub const sidebar_rows = @import("sidebar.zig").rows;          // []const ui.RowContributor (ADR-11)
pub const right_sidebar_modes = @import("contrib.zig").modes;  // []const ui.RightSidebarMode
pub const panel_kinds = @import("panels.zig").kinds;           // []const *const web.PanelKind (ADR-6)
pub const window_hooks = ...;                                   // []const ui.WindowHook  (top-level window messages)
pub const app_hooks = ...;                                      // []const app.AppHook    (broadcast window messages)
pub fn init(app: *App) !void
pub fn deinit(app: *App) void
pub fn onEvent(app: *App, ev: *const model.Event) void          // synchronous, UI thread, after the mutation
pub fn onSettingsChanged(app: *App, diff: *const settings.Diff) void
```

`features/<id>/state.zig` always exists:

```zig
pub const App = struct {};        // app-wide feature state      → App.features.<id>
pub const Window = struct {};     // per-window state            → Window.ext.<id>
pub const Workspace = struct {};  // per-workspace state         → Workspace.ext.<id>
pub const Pane = struct {};       // per-pane state              → Pane.ext.<id>
pub const Tab = struct {};        // per-surface state           → Tab.ext.<id>
// Each type may declare: pub fn deinit(self: *@This(), gpa: Allocator) void
//                        pub fn snapshot(self: *const @This(), w: *std.json.Stringify) !void   (session, ADR-9)
//                        pub fn restore(self: *@This(), v: std.json.Value, gpa: Allocator) !void
// Every type MUST have a valid `.{}` default. Feature state may hold pointers to model types, never embed them by value.
```

The settings of a feature live in `src/wmux_proto/settings/specs/<id>.zig` (shared with the CLI for offline `config` commands). Its CLI commands live in `src/wmux_cli/commands/<family>.zig` (families are listed in the CLI manifest, Appendix C).

### 1.4 Registries (all written once in W0-A3, then frozen)

| Registry file | Aggregates | Consumers |
|---|---|---|
| `features/manifest.zig` | `pub const modules = .{ @import("agents/mod.zig"), … };` one line per feature, sorted | everything below |
| `features/lifecycle.zig` | `init`, `deinit`, `onEvent`, `onSettingsChanged` (`inline for` + `@hasDecl`) | `App.zig`, `model/events.zig`, `settings/` |
| `features/ext.zig` | `AppExt`, `WindowExt`, `WorkspaceExt`, `PaneExt`, `TabExt` (explicit fields) | model structs, session |
| `rpc/registry.zig` | `rpc_methods` → `all_methods`, `by_name` (StaticStringMap) + duplicate check; `legacy_commands`; `text_verbs` | `rpc/dispatch.zig`, `system.capabilities` |
| `input/actions.zig` | joins `wmux_proto/actions_catalog.zig` with every `action_handlers` (unknown id or duplicate handler = `@compileError`) | KeyRouter, palette, menus, `wmux.action.run` |
| `ui/contrib.zig` | `menu_items`, `palette_providers`, `sidebar_rows`, `right_sidebar_modes`, `panel_kinds`, `window_hooks`, `app_hooks` | menus, palette, sidebar, right sidebar, web, WndProcs |
| `wmux_proto/settings/specs_manifest.zig` | `specs/<id>.zig` (one per feature) + duplicate-path check | settings layer, CLI `config`, schema dump |
| `wmux_cli/commands/manifest.zig` | `commands/<family>.zig` | CLI dispatch, help |
| `wmux_cli/agents/manifest.zig` | `agents/<agent>.zig` | hooks, installers, wrappers |

`features/ext.zig` shape (pre-seeded with every feature; empty structs are zero-size):

```zig
pub const WorkspaceExt = struct {
    agents: @import("agents/state.zig").Workspace = .{},
    notifications: @import("notifications/state.zig").Workspace = .{},
    status: @import("status/state.zig").Workspace = .{},
    // … one line per feature id, sorted
};
// AppExt / WindowExt / PaneExt / TabExt identical in shape.
```

### 1.5 Pre-seeded feature list (70 modules; owning wave in brackets)

`a11y`[7] `about`[1] `agent_chat`[5] `agent_messages`[5] `agent_status`[3] `agents`[3] `auto_naming`[5] `automation`[5] `browser`[2,5] `browser_profiles`[5] `canvas`[7] `chrome`[1] `comments`[4] `context_menus`[4] `copy_mode`[5] `custom_actions`[4] `custom_sidebars`[5] `debug`[1] `deeplinks`[3] `diff`[4] `dnd`[4] `dock`[5] `env_identity`[1] `events`[2] `feed`[5] `file_preview`[4] `files_explorer`[4] `find`[2] `find_in_dir`[4] `focus_history`[2] `global_search`[5] `groups`[4] `hibernation`[5] `hints`[5] `history`[4] `i18n`[7] `image_paste`[5] `install_cli`[7] `keep_awake`[5] `layouts`[4] `markdown`[4] `meta`[2] `notifications`[2,3] `palette`[2] `panes_surfaces`[2] `policy`[7] `quick_terminal`[0] `remote`[6] `remote_tmux`[6] `resume`[3] `session`[1] `settings_ui`[4] `shortcuts`[1] `sleepy_mode`[7] `status`[2] `sync_input`[0] `system`[1,2] `task_manager`[5] `terminal_io`[2] `textbox`[5] `tmux_compat`[3] `toasts`[3] `todo`[5] `tray`[3] `updater`[5] `vault`[5] `windows`[2] `workspace_status`[5] `workspace_style`[4] `workspaces`[2]

W0-A3 creates `mod.zig` (with `pub const id`) and `state.zig` for every module, a `logic/tests.zig` (empty `test {}`) for every module, and `actions.zig` (empty table, already declared in `mod.zig`) for the 13 modules with pre-existing behavior: `windows workspaces panes_surfaces chrome palette find notifications session browser quick_terminal sync_input layouts terminal_io`. Every other declaration file is created by the feature's owning WP. Action ownership for existing behaviors: `windows` (newWindow, closeWindow, toggleFullScreen, quit, showHideAllWindows), `chrome` (toggleSidebar, focusSidebar, toggleFileExplorer, focusRightSidebar, switchRightSidebarTo*, openSettings, reloadConfiguration), `workspaces` (newTab, closeWorkspace, renameWorkspace, editWorkspaceDescription, selectWorkspaceByNumber, next/prevSidebarTab, moveWorkspaceUp/Down), `panes_surfaces` (newSurface, closeTab, closeOtherTabsInPane, next/prevSurface, selectSurfaceByNumber, moveSurface*, renameTab, splits, focus*, toggleSplitZoom, equalizeSplits, resize-pane-*), `palette` (commandPalette, goToWorkspace, palette next/previous), `find` (find, findNext, findPrevious, hideFind), `notifications` (showNotifications, jumpToUnread, toggleUnread, markOldestUnreadAndJumpNext, triggerFlash), `session` (reopenPreviousSession, saveLayoutTemplate), `browser` (openBrowser, browser*), `terminal_io` (clearScreenKeepScrollback, `wmux.clearScreen`, `wmux.pasteFromClipboard`), `quick_terminal`, `sync_input`, `layouts` (their `wmux.*` ids). A feature not in this list requires a manifest + ext edit (one line each, `merge=union`) recorded in the WP spec.

### 1.6 Generic UI-thread plumbing (W0-A1/A2, then frozen)

| Facility | API | Replaces |
|---|---|---|
| `app/tasks.zig` | `pub const Task = struct { run: *const fn (*App, *Task) void, destroy: *const fn (*Task) void };` `app.tasks.post(task)` from any thread: mutex-protected queue + **one** `PostMessageW(msg_hwnd, WM_APP_TASK)` per empty→non-empty transition; the UI drains the whole queue. If posting fails the queue keeps the task (drained on the next post); on shutdown remaining tasks are destroyed. | every future `WM_APP+N`; `WM_APP+2..6` migrate to tasks in W0-A1 |
| `app/timers.zig` | `app.timers.start(ms, .{ .repeat = bool }, ctx, cb) TimerId`, `stop(id)`; ids from 1000 upward on `msg_hwnd` | the hand-numbered timer registry (quit=1, quick terminal=3, notif=4, ws_meta=5, balloons=100..107 migrate in W0-A1) |
| `ui/menus.zig` | `MenuBuilder` builds an HMENU from `ui.MenuItem{ site, group, order, title, action_id \| callback, when, checked }` for a `MenuSite` (`terminal tab tab_bar_blank workspace_row sidebar_blank sidebar_gear new_button main notification_row browser_page right_sidebar_mode_bar pane_buttons`). Item id = 1 + index into a per-invocation table; `TrackPopupMenuEx(TPM_RETURNCMD)`; targets captured as **UUIDs** before the modal loop and re-resolved after it. | the reserved menu-id ranges 9001–9504 |
| `app/modal.zig` | `app.modal.enter()/leave()` around every modal loop (TrackPopupMenuEx, MessageBox, DoDragDrop, WM_ENTERSIZEMOVE…WM_EXITSIZEMOVE). The RPC dispatcher holds mutating UI-lane requests while `modal.depth > 0` (ADR-3.2). | ad-hoc `closing` re-checks |
| `app/hooks.zig` | `ui.WindowHook{ msg, handler: fn (*Window, WPARAM, LPARAM) ?LRESULT }`, `app.AppHook{ msg, handler: fn (*App, WPARAM, LPARAM) ?LRESULT }`. All hooks for a message run in manifest order; the first non-null result is returned. | edits to `windowWndProc`/`msgWndProc` |
| `app/broadcast_window.zig` | a hidden **top-level** window (message-only windows do not receive broadcasts) receiving `WM_QUERYENDSESSION`, `WM_ENDSESSION`, `WM_POWERBROADCAST`, `WM_SETTINGCHANGE`, `WM_DISPLAYCHANGE` and the `TaskbarButtonCreated` registered message; dispatches to `app_hooks` | missing logoff/sleep/policy handling |
| choke points | `app/foreground.zig` (the only caller of `SetForegroundWindow`/`SetActiveWindow`/`BringWindowToTop`/`FlashWindowEx`/`AllowSetForegroundWindow`), `app/clipboard.zig` (the only clipboard access; fake in test mode), `app/runtime_env.zig` (parses every `WMUX_*` app input once, Appendix G), `app/paths.zig` (INSTALL/CLI/SHARE/CONFIG/STATE resolution) | scattered calls |
| `app/message_loop.zig` | `preTranslate(msg: *MSG) bool` called by `App.run` before `TranslateMessage`; W0 moves today's interception code (rename edit, address bar, palette/search edits, Ctrl+W in WebView2) here; W1-5 inserts the KeyRouter call | edits to `App.run` |
| `app/perform_action.zig` | the exhaustive switch over `apprt.Action`; **every arm is a one-line delegation** to a layer or `features/<id>/api.zig` function (stubs where not implemented), e.g. `.pwd => features.meta.api.onPwd(target, v)`, `.progress_report => features.status.api.onProgress(target, v)`, `.desktop_notification => features.notifications.api.onDesktopNotification(target, v)`, `.ring_bell => features.notifications.api.onBell(target)`, `.key_sequence, .key_table => input.chord.onGhostty(target, v)`, `.new_tab/.goto_tab/... => input.ghostty_interop.tabAction(...)` | the 1000-line `App.performAction` |

### 1.7 File ownership classes and the CCR process

| Class | Files | Who may edit |
|---|---|---|
| Owned | `features/<id>/**`, `wmux_proto/settings/specs/<id>.zig`, `wmux_cli/commands/<family>.zig`, `wmux_cli/agents/<agent>.zig`, `src/web/<app>/**`, `test/e2e/suites/<area>/<wp>.e2e.ps1`, `docs/wmux/features/<id>.md`, `changes/<wp>.md` | the WP that owns the feature/family in that wave (WP spec `owns:`) |
| Frozen | `App.zig`, `ui/Window.zig`, `model/**`, `rpc/types.zig`, `rpc/registry.zig`, `input/actions.zig`, `ui/contrib.zig`, `features/{manifest,ext,lifecycle}.zig`, `fast_tests.zig`, `test_index.zig`, all manifests, `src/config/Config.zig`, `src/input/Binding.zig`, `src/input/command.zig`, `src/apprt/action.zig`, `include/ghostty.h`, `src/Surface.zig`, `src/apprt/surface.zig`, `src/Command.zig`, `src/termio/**`, `build.zig`, `src/build/**`, `platform/webview2.zig` (after W1-6), `platform/d2d.zig`/`dwrite.zig` (after W1-8) | only the WP listed for that file in the wave's hot-file table (§14), or via a CCR |
| Layer | `app/ platform/ ui/ input/ rpc/ settings/ web/` (non-frozen files) | the layer's owning WP in that wave (§14 tables) |
| Shared-appendable | `wmux_proto/actions_catalog.zig`, `wmux_proto/events_catalog.zig`, `platform/win32.zig` (marked per-WP sections), `THIRD_PARTY_LICENSES.md`, `src/web/_vendor/README.md` | any WP; one entry per line, sorted; `.gitattributes merge=union` |
| Proto | other `src/wmux_proto/**` files | the WP that creates the file (named in its spec); after that wave the file is frozen and changes go through a CCR |

The integrator's wave interface commit (§14.1) may touch any file.

A WP that needs a frozen/layer file it does not own writes a **Core Change Request** `docs/arch/ccr/<wp>-<n>.md` (what, why, exact diff sketch). The integrator either folds it into the current wave's owner of that file or schedules it for the next wave; the WP ships behind a stub meanwhile. `scripts/check-ownership.ps1` (merge gate) rejects diffs outside the WP spec's `owns`/`touches`/`appends`; `scripts/check-manifest.ps1` rejects a `features/*/mod.zig` missing from the manifest or ext.

### 1.8 Wave 0 migration (single core-lane agent; each step merged and gated before the next)

**W0-A1: App and ipc extraction (behavior-preserving).**
1. Create the layer directories. Move `win32.zig`→`platform/win32.zig`, `taskbar.zig`→`platform/taskbar.zig`, `webview2.zig`→`platform/webview2.zig`, `webview2_scratch.zig`→ delete (document in the commit), `QuickTerminal.zig`→`features/quick_terminal/`.
2. Move IPC handlers (`App.zig` 2737–4725) verbatim into `features/<domain>/legacy.zig` as `legacy_commands` tables: `workspaces` (workspace-*), `panes_surfaces` (tab-*, surface-*, new-split, swap-split, break-pane, move-pane), `terminal_io` (send, read-screen, capture-pane), `browser` (open, navigate, eval, snapshot, click, fill), `notifications` (notify, flash-pane), `status` (set-status, set-progress, log), `session` (session-*), `layouts` (select-layout), `sync_input` (sync-input), `chrome` (toggle-right-sidebar). The pipe server moves to `rpc/server/legacy_pipe.zig`, the protocol parser to `rpc/compat/legacy_json.zig`; `handleIpcRequest` becomes a lookup over the aggregated `legacy_commands`.
3. Move notification code (`App.zig` 2099–2745, 4730–4967) to `features/notifications/legacy_ring.zig`; workspace metadata (2973–3150) and `ws_meta.zig` to `features/meta/`; the WebView2 environment (5013–5118) to `web/env.zig`; the update checker to `features/updater/`; config-file ops (1652–1960) to `settings/legacy_config_files.zig`.
4. Add `app/{tasks,timers,runtime_env,paths,foreground,clipboard,modal,message_loop,perform_action,hooks,broadcast_window}.zig` and migrate `WM_APP+2..6` and every msg_hwnd timer to them.
5. `App.zig` ends ≤ ~1,500 lines.

**W0-A2: Window extraction and model.**
1. `model/Workspace.zig` (heap, `std.ArrayList(*Workspace)` in the window; `MAX_WORKSPACES` gone), `model/Pane.zig` (was `PaneContainer`; `tabs: std.ArrayList(*Tab)`; `MAX_TABS` gone), `model/Tab.zig` (was `Pane`; holds title, title source, content, legacy per-tab fields), `model/TabContent.zig`. Rename in two commits: `Pane`→`Tab` first, then `PaneContainer`→`Pane`.
2. `model/ops/*.zig`: container-explicit mutators taking explicit targets (fixes ui-model bugs 8.1#1 and #13 by construction) and ONE `ops.surface.insert(pane, tab, index)` used by all seven former tab-creation sites and session restore.
3. `model/layout.zig: computeLayout(tree, rect, scale) LayoutResult` (leaves, dividers, node rects) consumed by layout, attention rings, pane buttons, divider paint and divider hit-test; divider drag stores the dragged node's own rect (fixes nested divider drag 8.1#2; `resizeSplit` uses node dimension).
4. Split `Window.zig` into `ui/Window.zig` (HWND, chrome state, WndProc dispatch) plus `ui/{chrome,tabbar/*,sidebar/legacy_gdi,right_sidebar/legacy_strip,overlays/*,menus,rename,placement}.zig`; convert all context menus to `MenuBuilder` items contributed from the owning layer/feature.

**W0-A3: Skeleton.**
1. `features/manifest.zig`, all 70 stub modules (§1.5), `features/ext.zig`, `features/lifecycle.zig`, `ui/contrib.zig`, `input/actions.zig` (catalog join; handlers empty), `rpc/types.zig` + `rpc/registry.zig`, `fast_tests.zig`, `test_index.zig`; move the legacy per-tab fields into feature ext state (`status`: status text, progress, log ring; `notifications`: attention, bell/exited status; `sync_input`: synchronized).
2. `model/ids.zig` + `model/registry.zig` (ADR-2) with handles on every object, minted at creation; `model/events.zig` bus (ADR-3.10) emitting from `model/ops/*` for every existing lifecycle operation.
3. `src/wmux_proto/` with uuid, handles, selectors, envelope, errors, idformat, paths, pipe_name, env_names, channel, utf8; the **complete** `actions_catalog.zig` (Appendix A) and `events_catalog.zig` (cmux catalog + `wmux.*`); settings spec types, `specs_manifest.zig` and one empty `specs/<id>.zig` per feature.
4. `src/wmux_cli/` executable target that prints `cmux <version>`; manifests for commands (families of Appendix C, empty) and agents (19 stubs).
5. `build.zig` delegates to a new `src/build/WmuxSteps.zig` that defines **all** later steps now, pointing at stub files: `test-fast`, `test-cli`, `settings-schema`, install of `cli\cmux.exe` + `cli\wmux.com` + `cli\cmux` + `cli\wmux`, install of `src/web/**` to `share/wmux/web/`, and `remote-daemon` (no-op until W6). No later WP edits `build.zig`.
6. `.gitattributes`: `merge=union` for the manifests, `ext.zig`, catalogs and `platform/win32.zig`; `eol=lf` for `src/wmux_cli/scripts/*`.
7. Pre-wire every hook point Wave 1 needs (full list in §14.3): the `wmux:` Ghostty binding action, core `src/Surface.zig` → termio plumbing for the protected environment, job handle and scrollback replay, apprt `Surface.zig` delegating stubs, `App.init`/`ui/Window.zig` facades, `TabContent` variants, link libraries.

Gate for every W0 step: debug build, `zig build test -Dtest-filter="unit: "` plus the existing CI filters (`sidebar`, `wsl`, `win-pwd`, `ipc:`), the W0-B smoke e2e suite, a release build and 10 minutes of human dogfooding. Reviewable as move-only (`git diff --color-moved`).

Current→target file map (W0): `App.zig`→`App.zig`+`app/*`+features; `Window.zig`→`ui/Window.zig`+`ui/*`+`model/*`; `PaneContainer.zig`→`model/Pane.zig`+`ui/tabbar/paint.zig`; `Pane.zig`→`model/Tab.zig`+`model/TabContent.zig`; `Sidebar.zig`→`ui/sidebar/legacy_gdi.zig` (replaced in W1-8); `RightSidebar.zig`→`ui/right_sidebar/legacy_strip.zig`; `ipc.zig`→`rpc/server/legacy_pipe.zig`+`rpc/compat/legacy_json.zig`; `SessionState.zig`→`features/session/legacy_v2.zig`; `agent_session.zig`→`features/agents/legacy_store.zig`; `ws_meta.zig`→`features/meta/probes.zig`; `BrowserPane.zig`→`web/BrowserPane.zig`; `AttentionRing/FlashOverlay/PaneButtons/Scrollbar.zig`→`ui/overlays/`; `WindowState.zig`→`ui/placement_state.zig`.

### 1.9 Risks

- Big-bang move regressions → one agent, numbered commits, move-only diffs, smoke e2e per step, dogfood gate.
- Aliases hide where code lives → aliases allowed only for moved functions; `check-manifest.ps1` warns on new aliases after W0.
- Comptime registry cost → bounded (~700 methods); quota set locally in registries.

---

## ADR-2. Object identity and handles

### Decision

Windows, workspaces, groups, panes and surfaces carry a UUID (persisted, adopted on restore) and a per-kind ref ordinal (minted once, never reused, persisted). Indexes are positions computed on demand. One process-wide `HandleRegistry` resolves all three forms.

### 2.1 Formats

- **UUID**: RFC 4122 v4 from `std.crypto.random`, rendered **uppercase** `8-4-4-4-12` (Swift `uuidString`). Parsing is case-insensitive and tolerates `{}` braces.
- **Ref**: `<kind>:<N>`, N ≥ 1, kinds `window`, `workspace`, `workspace_group`, `pane`, `surface`. `tab:N` parses as `surface:N`; text output in tab contexts prints `tab:N` where cmux does. Notifications are addressed by UUID (`notification_id`).
- **Index**: 0-based input only, never stored (§2.4).
- **Ghostty core id** (`core_surface.id`, u64): internal; still exported as `GHOSTTY_SURFACE_ID`; the registry maps it to the tab UUID so legacy ids keep resolving. `BrowserPane.ipc_id` stays resolvable **only** in the legacy JSON adapter.

### 2.2 Types (`wmux_proto/uuid.zig`, `wmux_proto/handles.zig`, `model/registry.zig`)

```zig
pub const Uuid = extern struct { b: [16]u8,
    pub fn v4() Uuid; pub fn parse(s: []const u8) error{InvalidUuid}!Uuid;
    pub fn format(self: Uuid, w: *std.Io.Writer) !void; };            // uppercase
pub const Kind = enum { window, workspace, workspace_group, pane, surface };
pub const Ref = struct { kind: Kind, n: u32 };                         // "pane:7"; "tab:7" → .surface
pub const HandleText = union(enum) { uuid: Uuid, ref: Ref, index: u32, legacy_core_id: u64 };
pub fn parseHandle(expect: Kind, s: []const u8) error{ Blank, Invalid, WrongKind }!HandleText;
pub const Handle = struct { uuid: Uuid, ref: u32 };

pub const HandleRegistry = struct {                                    // model/registry.zig, UI thread only
    next: std.EnumArray(Kind, u32),                                    // high-water marks (persisted in session)
    reserved: std.EnumArray(Kind, u32),                                // persisted reservation ceiling (crash safety)
    by_uuid: std.AutoHashMapUnmanaged(Uuid, Entry),                    // Entry{ kind, ref, ptr: *anyopaque }
    by_ref: std.AutoHashMapUnmanaged(Ref, Uuid),
    by_core_id: std.AutoHashMapUnmanaged(u64, Uuid),
    pub fn mint(self: *HandleRegistry, gpa: Allocator, kind: Kind, ptr: *anyopaque) !Handle;
    pub fn adopt(self: *HandleRegistry, gpa: Allocator, kind: Kind, saved: Handle, ptr: *anyopaque) !Handle; // keeps uuid+ref unless live collision → mint
    pub fn retire(self: *HandleRegistry, uuid: Uuid) void;             // ref stays burned forever
    pub fn get(self: *const HandleRegistry, comptime T: type, kind: Kind, uuid: Uuid) ?*T;
};
```

**Crash-safe reservation.** When minting would exceed `reserved[kind]`, the registry raises the ceiling by 64 and synchronously writes `STATE\run\handles.json` (`{"window":…,"workspace":…}`; atomic replace). At startup `next = max(snapshot high-water, reserved)`. A crash therefore never re-issues a ref that a script may have seen.

### 2.3 Model fields (frozen in W0-A3)

```zig
// ui/Window.zig (model part)    handle: Handle, workspaces: std.ArrayList(*Workspace), groups: std.ArrayList(*Group),
//                               selected: ?*Workspace, ext: features.WindowExt
// model/Workspace.zig           handle, window: *Window, title: Title, description: ?[]u8, cwd: ?[]u8,
//                               env: std.StringArrayHashMapUnmanaged([]u8), tree: SplitTree(Pane),
//                               focused_pane: ?*Pane, zoomed_pane: ?*Pane, group: ?*Group, pinned: bool,
//                               ext: features.WorkspaceExt
// model/Group.zig               handle, window: *Window, name: []u8, collapsed: bool, pinned: bool,
//                               anchor: ?*Workspace, ext-free (style lives in workspace_style/groups state)
// model/Pane.zig                handle, workspace: *Workspace, tabs: std.ArrayList(*Tab), selected: usize,
//                               layout_rect: Rect, ext: features.PaneExt
// model/Tab.zig                 handle, pane: *Pane, content: TabContent, title: Title, pinned: bool,
//                               lifecycle_id: Uuid (re-minted per terminal spawn), cwd: ?[]u8, ext: features.TabExt
pub const Title = struct { custom: ?[]u8 = null, auto: ?[]u8 = null, source: enum { auto, user, process, agent } = .auto };
```

`Title.custom` set by a user rename sticks: OSC titles only update `auto` (fixes "renames don't stick", B12). `pinned`, `group` and the order of `workspaces` are core because they determine indexes.

### 2.4 Index semantics

| Kind | Index means | Resolved relative to |
|---|---|---|
| window | position in `App.windows` (creation order) | global |
| workspace | displayed sidebar order (pinned first, then groups flattened in display order) | `--window`/`window_id`, else caller's window, else active window |
| pane | split-tree leaf order, depth-first, `a` before `b` | workspace |
| surface | tab order within a pane (`pane.surfaces`); for workspace-level lists, pane order then tab order (`surface.list`) | pane or workspace |

### 2.5 Output convention

Every object in a result carries `<kind>_id`, `<kind>_ref` and, where ordered, `index`. Cross references use the same pairs (`workspace_id`, `workspace_ref`). For cmux readers, `stable_surface_id` / `stable_workspace_id` are emitted equal to the normal ids (wmux has one identity per object). The CLI's `--id-format refs|uuids|both` only formats output (default `refs`).

### 2.6 Resolution and routing (`rpc/router.zig`)

- Every `*_id` param accepts a UUID string, a ref string, or (wmux leniency, Appendix E) a JSON integer index.
- A non-canonical selector key (`workspaceId`, `surfaceID`, `tabId`, …) fails with `invalid_params` and message `Unsupported parameter '<x>'; use '<canonical>'`.
- An explicit selector that does not resolve fails closed (`not_found`) and never falls back to the focused object.
- Server precedence: `window_id` → `group_id` → `workspace_id` → `surface_id` (aliases `terminal_id`, `tab_id`) → `pane_id` → caller context (§3.9) → **active window** = the most recently activated wmux window (tracked from `WM_ACTIVATE`), never `GetForegroundWindow()` (fixes the windows[0] fallback).
- Routing error messages use cmux's exact strings (`Workspace not found`, `Surface not found for the given surface_id`, `No focused surface`, …) kept in `wmux_proto/errors.zig`.

### 2.7 Persistence

The session file stores `handles.next` and each object's `{id, ref}` (ADR-9). Restore calls `adopt()`; a UUID that collides with a live object (e.g. `restore-session --from` adding windows) gets a fresh UUID and ref. `CMUX_WORKSPACE_ID` and `CMUX_SURFACE_ID` therefore survive relaunch. The v2 session format has no ids; migration mints them.

### 2.8 Legacy mapping

`rpc/compat/legacy_json.zig` translates `{cmd,args}` integer indexes into v2 index selectors with the same meaning as today (window = target window; `workspace`, `pane`, `tab` indexes), keeps the old `data` result shapes and the `@errorName`-style error strings, and accepts decimal/`0x` core ids and browser `ipc_id`s. `+surface list`'s decimal u64 ids exist only in that adapter (v2 output uses UUIDs, avoiding the >2^53 precision bug).

Risks: casing mismatches (always parse and compare bytes); stale refs if `next` is not persisted (unit-tested round trip).

---

## ADR-3. Control plane

### 3.1 Naming, discovery and single instance

| Item | Value |
|---|---|
| channel | compiled default `stable` (ReleaseFast/ReleaseSafe; overridable at build time with `-Dwmux-channel=<name>`, e.g. `nightly`) or `debug` (Debug builds); `WMUX_TAG=<tag>` → `dev-<tag>`; `WMUX_CHANNEL=<name>` overrides all. Sanitized to `[a-z0-9-]{1,40}`. Tests use `test-<8hex>`. |
| `sidhash8` | lowercase hex of the first 4 bytes of SHA-256(UTF-8 user SID string) |
| `session` | `ProcessIdToSessionId(GetCurrentProcessId())` |
| control pipe | `\\.\pipe\wmux-<channel>-<sidhash8>-s<session>`, e.g. `\\.\pipe\wmux-stable-3f9c1a0b-s1` |
| launch pipe | control name + `-launch` |
| legacy pipe | `\\.\pipe\wmux-ipc-<pid>`, served by the same server, legacy JSON only, **one release** (removed at M3) |
| marker | `STATE\run\instance.json` = `{pipe, launch_pipe, pid, exe, version, protocol: 2, channel, boot_id, started_at}`, atomic replace at startup, deleted on clean exit if it still names us |
| security | owner = user SID; DACL `D:P(A;;GA;;;<user SID>)`; default medium mandatory label (low-IL denied); `PIPE_REJECT_REMOTE_CLIENTS`; `FILE_FLAG_FIRST_PIPE_INSTANCE` on the first instance; handles non-inheritable. `allowAll` adds `(A;;GRGW;;;WD)`. |
| squatting | if `FILE_FLAG_FIRST_PIPE_INSTANCE` fails and the existing server is not ours (`GetNamedPipeServerProcessId` → token user SID ≠ ours), use `<name>-alt-<8hex>` and record it in the marker |

The user and logon session are in the name because `\\.\pipe` is machine-global (RDP and fast user switching otherwise collide). The name is stable per user/session/channel and computable by any client, the Windows analog of cmux's stable socket path. `CMUX_SOCKET_PATH`/`WMUX_SOCKET_PATH` carry the full pipe path.

**Single instance per channel** (`app/single_instance.zig`, W1-1): at startup the app tries to create the launch pipe with `FILE_FLAG_FIRST_PIPE_INSTANCE`. If it exists and its server is ours, the new process sends `app.launch {intent, argv, cwd, paths, uri}` (intent ∈ `open | new_window | activate | uri`), calls `AllowSetForegroundWindow(server_pid)` and exits 0. The launch pipe accepts **only** `app.launch` and is always on, even with `socketControlMode=off` (equivalent to the same user starting `wmux.exe` with arguments). Test instances never collide because their channel is unique.

### 3.2 Server structure (`rpc/server/`)

- **Threads.** One accept thread keeps one spare overlapped instance in `ConnectNamedPipe`. Each accepted connection gets its own **connection thread** (thread-per-connection; chosen over IOCP for implementability at ≤64 clients). A **worker pool** of 4 threads serves the `worker` lane. The UI thread serves the `ui` lane through `app.tasks`.
- **Connection** = `{ pipe, id, generation: u64, client_pid, client_job_surface: ?Uuid, auth: AuthState, bucket: TokenBucket, framer: LineFramer, stream: ?*Subscriber, write_mutex }`.
- **Framing.** Newline-delimited UTF-8 (LF or CRLF; blank lines ignored). Authorized line cap 16 MiB (a 15 MiB `terminal.paste` fits); pre-authorization reads capped at 4 MiB / 2 s. Replies are always one line. Invalid UTF-8 → `invalid_utf8`.
- **Ordering.** A connection processes one request at a time and reads the next line only after the current reply is written or expired: replies are in request order by construction. Pipelined requests simply queue in the pipe buffer.
- **Lanes.** `pipe` methods run on the connection thread (no model access): `system.ping`, `system.capabilities`, `auth.login`, `events.stream` setup, `wmux.agent.hook` enqueue. `worker` methods run on the pool and may read files and processes but not the model. `ui` methods hop to the UI thread.
- **Request lifecycle (ui lane).** State `queued → running → done | deferred`, or `queued → expired`. The connection thread posts the task and waits on the request's completion event for `deadline_ms` (default 10,000). On timeout: CAS `queued→expired` succeeds → reply `timeout {stage:"main_actor", deadline_ms, retryable:true}`; otherwise the request is running → reply `timeout {…, retryable:false}` and mark it abandoned (its late reply is dropped). The UI thread skips expired requests.
- **Modal hold.** While `app.modal.depth > 0`, UI-lane requests whose access is not `.read` stay queued (their deadline still runs). This prevents mutations inside TrackPopupMenu/MessageBox loops.
- **Deferred replies.** `ctx.deferReply()` returns `Deferred{ conn_id, generation, request_seq }`; `rpc.complete(deferred, result)` may run on any thread. A completion whose connection is gone, whose generation changed or whose request expired is dropped. This fixes stale async browser replies reaching the next client (ipc-cli 9.1#2, browser B2). Deferred requests use the method's `deadline_ms` (async methods set their own budget, e.g. `browser.wait` = its `timeout_ms` + 2 s).
- **Shutdown.** Stop accepting; reply `overloaded {reason:"server_stopping"}` to queued requests; cancel I/O; join threads before `msg_hwnd` is destroyed.

### 3.3 Admission and rate limits (cmux numbers)

- At most **64** live connections, **64** pending connections with a **15 s** wait cap, at most **16** unauthenticated peers being read. Overflow is accepted, answered with `overloaded {retryable:true, retry_after_ms, reason}` (`pool_saturated`, `pending_expired`, `preauthorization_saturated`, `accept_buffer_full`, `server_stopping`) and closed. The command never ran.
- Methods flagged `polling` share a per-connection token bucket: burst 9, one token per 100 ms. Excess → `rate_limited {retry_after_ms}`. Polling methods: `system.tree`, `system.identify`, `system.top`, `system.memory`, `window.list`, `window.current`, `workspace.list`, `workspace.current`, `pane.list`, `pane.surfaces`, `surface.list`, `surface.current`, `surface.read_text`, `surface.read_selection`.

### 3.4 Envelope (`wmux_proto/envelope.zig`)

```
→ {"id":"3f2a…","method":"workspace.create","params":{"title":"api","focus":false}}
← {"id":"3f2a…","ok":true,"result":{"workspace_id":"9B69…","workspace_ref":"workspace:4","index":3}}
← {"id":7,"ok":false,"error":{"code":"not_found","message":"Workspace not found","data":{"selector":"workspace_id"}}}
```

- `id`: string, number or absent; echoed (absent → `null`). `method` is trimmed. Non-object `params` → `{}`.
- Error object: `{code, message, data?, reason?, action?, details?}`.
- Fixed fallback line when encoding fails: `{"ok":false,"error":{"code":"encode_error","message":"Failed to encode JSON"}}`.
- Pre-dispatch checks: invalid UTF-8 → `invalid_utf8`; bad JSON → `parse_error "Invalid JSON"`; not an object → `invalid_request "Expected JSON object"`; empty method → `invalid_request "Missing method"`; unknown → `method_not_found "Unknown method"`.
- Capability envelope: any line (v2 JSON, legacy JSON or text) may be prefixed `_cmux_capability_v1 <token> ` (cmux wire format, verified); the prefix is stripped before sniffing and verified per line in `cmuxOnly` mode, ignored in other modes.
- Protocol sniffing per line: first non-space byte `{` and a `"method"` key → v2; `{` and a `"cmd"` key → legacy wmux JSON; anything else → cmux text-v1.

### 3.5 Error codes (`wmux_proto/errors.zig`; all verified present in cmux)

`parse_error invalid_utf8 invalid_request method_not_found invalid_params not_found surface_unavailable unavailable invalid_state not_supported busy cancelled timeout overloaded rate_limited input_queue_full forbidden confirmation_required auth_required auth_failed auth_unconfigured disabled capability_disabled browser_disabled permission_denied js_error file_not_found stale_state internal_error encode_error slow_consumer remote_relay_denied`

Handlers return `rpc.Error = error{RpcFailed}` after `ctx.fail(...)`. Any other Zig error escaping a handler is mapped by `errors.fromZig`: `OutOfMemory`→`internal_error`, `*NotFound`/`Unknown*`→`not_found`, `Missing*`/`Bad*`/`Invalid*`→`invalid_params`, `CoreNotReady`→`surface_unavailable`, else `internal_error` with `data.error = @errorName(err)`. Raw `@errorName` strings survive only in the legacy JSON adapter.

### 3.6 Method type, Ctx, naming, capabilities (`rpc/types.zig`, frozen in W0-A3)

```zig
pub const Lane = enum { pipe, worker, ui };
pub const Access = enum { read, mutate, focus, input, exec, admin };        // readOnly mode admits only .read
pub const Method = struct {
    name: [:0]const u8,                         // cmux name, or "wmux.<domain>.<verb>"
    handler: *const fn (ctx: *Ctx) Error!void,
    lane: Lane = .ui,
    access: Access = .mutate,
    polling: bool = false,
    focus_intent: bool = false,                 // only the cmux allowlist (§3.11)
    deadline_ms: u32 = 10_000,                  // 0 = streaming / long-poll
    relay: bool = false,                        // remote relay allowlist (ADR-13), default deny
    hidden: bool = false,                       // omitted from system.capabilities
    test_only: bool = false,                    // wmux.debug.*: Debug builds or WMUX_TEST_MODE only
};
pub const Ctx = struct {
    app: *App, arena: Allocator, id: std.json.Value, method: *const Method, params: std.json.ObjectMap,
    caller: ?Caller, origin: Origin,            // .socket{conn,pid} | .in_process{.web_panel,.palette,.automation,.test} | .relay{workspace}
    pub fn param(self: *Ctx, comptime T: type, key: []const u8) Error!?T;     // wrong type → invalid_params (never "absent")
    pub fn params(self: *Ctx, comptime T: type) Error!T;                       // std.json.parseFromValueLeaky + canonical-key check
    pub fn resolveWindow(self: *Ctx, sel: Selectors) Error!*Window;
    pub fn resolveWorkspace(self: *Ctx, sel: Selectors) Error!*Workspace;
    pub fn resolvePane(self: *Ctx, sel: Selectors) Error!*Pane;
    pub fn resolveTab(self: *Ctx, sel: Selectors) Error!*Tab;
    pub fn ok(self: *Ctx, value: anytype) void;
    pub fn okRaw(self: *Ctx, json: []const u8) void;
    pub fn fail(self: *Ctx, code: ErrorCode, msg: []const u8, data: anytype) Error;
    pub fn deferReply(self: *Ctx) Deferred;
};
pub const LegacyCommand = struct { cmd: []const u8, handler: *const fn (*App, *LegacyRequest) anyerror!void, read_only: bool };
pub const TextVerb = struct { name: []const u8, method: []const u8, parse: *const fn (args: []const u8, arena: Allocator) anyerror!std.json.Value, format: *const fn (result: std.json.Value, w: *std.Io.Writer) anyerror!void };
```

- Names are exactly cmux's (Appendix B). wmux-only methods are `wmux.<domain>.<verb>`. Out-of-scope cmux families are served by stubs returning `not_supported {data.reason:"not_available_on_windows"}` and are never listed in capabilities.
- `system.capabilities` (pipe lane) returns `{protocol:"cmux-socket", version:2, socket_path, access_mode, capabilities:{wmux:{version, build, channel, platform:"windows"}}, methods:[sorted]}` where `methods` = registry minus `hidden`, minus `test_only` outside test mode, minus families disabled by settings, policy or availability (e.g. `browser.*` after `cmux disable-browser`, stored as `wmux.browser.enabled=false`, or when WebView2 is missing).
- `system.identify` returns cmux's keys: `socket_path`, `focused`, `caller`, `bundle_identifier` (AUMID), `app_bundle_path` (INSTALL), `app:"wmux"`, `version`, `build`.

### 3.7 Compatibility adapters

- **Legacy wmux JSON** (`rpc/compat/legacy_json.zig`): every current command (37: open, navigate, eval, snapshot, click, fill, workspace-list/-new/-select/-close/-set-description, tab-list/-new/-select/-close, send, notify, surface-list/-focus, new-split, swap-split, set-status, set-progress, log, read-screen, capture-pane, select-layout, sync-input, break-pane, move-pane, flash-pane, toggle-right-sidebar, session-capture/-resume/-list/-save/-restore) keeps working until wmux 2.0. W0 registers the moved handlers directly; each W2/W3 WP re-points the commands of its feature to its v2 implementation through an arg/result adapter in its `features/<id>/legacy.zig`, then deletes the old handler. Behavior change toward cmux: legacy `log` stops creating notifications. Mapping table: Appendix B.3.
- **cmux text-v1** (`rpc/compat/text_v1.zig`, framework in W1-1): `<verb> <args>` (case-insensitive verb, split on the first space) → a feature's `TextVerb` → v2/`wmux.*` method → cmux text reply (`OK …`, `ERROR: …`, `PONG`), including `ERROR: overloaded retry_after_ms=<n> reason=<r>` and `ERROR: timeout retryable=<bool> <msg>`. W1-1 ships `ping`, `auth`, `help`; features register verbs (`set_status`, `report_pwd`, …) in their `text_verbs.zig`. Priority is low on Windows (raw-socket tooling is rare; cmux's own CLI does not run on Windows), so remaining verbs land in W5.

### 3.8 Access modes and authorization (`rpc/auth.zig`)

Setting `automation.socketControlMode` (cmux key). Values: `off | cmuxOnly | automation | password | allowAll` plus wmux's `readOnly`. Parsing ignores case, `-` and `_`; aliases `wmuxOnly`=`cmuxOnly`, `full`=`allowAll`, `notifications`=`automation`, `openAccess`=`allowAll`. **Default `cmuxOnly`** (cmux parity; a behavior change for wmux, with an actionable error: `forbidden: wmux control socket is in cmuxOnly mode; run from a wmux terminal or set "automation.socketControlMode" to "automation" in ~/.config/wmux/wmux.json`).

| Mode | Admitted | Mechanism |
|---|---|---|
| `off` | nobody (no control pipe; launch pipe stays) | listener not created |
| `cmuxOnly` | descendants of this wmux, or same-user peers presenting a valid capability on the line | `isDescendant(pid)` ∨ capability (below) |
| `automation` | any same-user local process | DACL |
| `password` | same-user peers after `auth.login {password}` (v2) or `auth <pw>` (text) | constant-time SHA-256 compare; cmux strings |
| `allowAll` | any local process (remote still rejected) | DACL adds Everyone |
| `readOnly` (wmux) | same-user, `Access.read` methods only | DACL + access filter |

- **`isDescendant(pid)`** = `inInstanceJob(pid)` ∨ `ancestryWalk(pid)`. `inInstanceJob`: every terminal tab is spawned into its own job nested under the instance job (W1-3, ADR-3.9), and `IsProcessInJob(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, pid), instance_job)` survives reparenting and PID reuse. `ancestryWalk`: Toolhelp snapshot, ≤32 levels, each parent's creation time (`GetProcessTimes`) must precede its child's, must reach the wmux PID. Results are cached per connection.
- **Capability**: secret = 32 random bytes protected with `CryptProtectData(CRYPTPROTECT_UI_FORBIDDEN)` in `STATE\run\socket-capability.bin` (persistent; regenerated per launch for `debug`/`test-*` channels). Token = base64url(HMAC-SHA256(secret, `"wmux-cap-v1|" ++ channel`)), compared in constant time. Exported as `CMUX_SOCKET_CAPABILITY`/`WMUX_SOCKET_CAPABILITY`. Covers WSL interop and detached/rescheduled processes whose ancestry is broken.
- **Password sources** (server): app env `WMUX_SOCKET_PASSWORD`/`CMUX_SOCKET_PASSWORD` → `automation.socketPassword` (cmux key) → DPAPI file `STATE\run\socket-control-password.bin` (written by Settings).
- **Overrides**: app env `CMUX_SOCKET_ENABLE`/`CMUX_SOCKET_MODE` (and `WMUX_*` twins); managed policy `HKLM|HKCU\Software\Policies\wmux\SocketControlMode` wins and only accepts `cmuxOnly` or `off` (malformed → `off`). The legacy Ghostty key `socket-control` (`on`→`automation`, `read-only`→`readOnly`, `off`→`off`) applies only when explicitly set in the user's Ghostty config (detected through `Config._replay_steps`, not through its default value) and the JSON key is absent.
- **Live changes**: a mode or password change re-evaluates live connections (dropping unauthorized ones), rebuilds the DACL for new instances and starts/stops the listener without a restart.
- `cmux socket-status` reports all of this offline (ADR-4).

### 3.9 Caller context and the terminal environment

**Caller context** (`rpc/router.zig: resolveCaller`), in order: (1) `params.caller {workspace_id, surface_id|tab_id}` (cmux field, inside `params`), validated; (2) the client PID's surface job (`client_job_surface`, the Windows analog of cmux's `caller_tty`, robust to stale env); (3) null. The resolved caller is echoed by `system.identify`/`system.tree`/`system.top` and is the routing fallback before the active window. The CLI also resolves targets client-side per the cmux contract and sends explicit ids (ADR-4.6).

**Environment exported into every terminal** (W1-3). Set by `Surface.defaultTermioEnv` and re-applied **last** through a new protected-env hook in `src/termio/Exec.zig` (after the Ghostty `env` override and workspace/layout env), so nothing can override them:

| Variable | Value |
|---|---|
| `CMUX_WORKSPACE_ID`, `WMUX_WORKSPACE_ID` | workspace UUID |
| `CMUX_SURFACE_ID`, `WMUX_SURFACE_ID`; `CMUX_PANEL_ID` | tab (surface) UUID; `PANEL` is cmux's legacy alias |
| `CMUX_TAB_ID` | workspace UUID (cmux legacy meaning; no `WMUX_TAB_ID`) |
| `CMUX_PANE_ID`, `WMUX_PANE_ID` | pane UUID at spawn (informational) |
| `CMUX_TERMINAL_LIFECYCLE_ID`, `WMUX_TERMINAL_LIFECYCLE_ID` | `Tab.lifecycle_id`, new per spawn |
| `CMUX_SOCKET_PATH`, `WMUX_SOCKET_PATH` | control pipe path |
| `CMUX_SOCKET` | empty string (deprecated alias; prevents an inherited value from shadowing) |
| `CMUX_SOCKET_CAPABILITY`, `WMUX_SOCKET_CAPABILITY` | capability token |
| `CMUX_SOCKET_PASSWORD` | only when the app itself was launched with one |
| `CMUX_BUNDLE_ID`, `WMUX_BUNDLE_ID` | AUMID: `wmux.app` (stable) or `wmux.app.<channel>` |
| `CMUX_BUNDLED_CLI_PATH`, `WMUX_BUNDLED_CLI_PATH` | absolute `INSTALL\cli\cmux.exe` |
| `CMUX_SHELL_INTEGRATION_DIR` | `SHARE\wmux\shell-integration` |
| `CMUX_HISTORY_FILE` (W5) | `STATE\history\surface-<uuid>.history` |
| `CMUX_PORT`, `CMUX_PORT_END`, `CMUX_PORT_RANGE` (W5) | per-workspace port block (`automation.portBase` 9100, `automation.portRange` 10) |
| `TERM`, `COLORTERM=truecolor`, `TERM_PROGRAM=ghostty`, `TERM_PROGRAM_VERSION` | `TERM=xterm-256color` unless the Ghostty `term` key is explicitly set (Windows deviation: WSL distros and ssh hosts lack `xterm-ghostty` terminfo) |
| `GHOSTTY_PID`, `GHOSTTY_SURFACE_ID`, `GHOSTTY_BIN_DIR` | unchanged (legacy) |
| `PATH` | **prepend** `STATE\shims\<build-id>\agents` (only while any agent integration is enabled) then `INSTALL\cli`; the existing append of `INSTALL` stays at the end for legacy scripts |
| `WSLENV` | append `CMUX_WORKSPACE_ID/u:CMUX_SURFACE_ID/u:CMUX_PANEL_ID/u:CMUX_TAB_ID/u:CMUX_PANE_ID/u:CMUX_TERMINAL_LIFECYCLE_ID/u:CMUX_SOCKET_PATH/u:CMUX_SOCKET_CAPABILITY/u:CMUX_BUNDLED_CLI_PATH/up:TERM_PROGRAM/u` + `WMUX_` twins (+ `CMUX_SOCKET_PASSWORD/u` when set) |

Inherited `ANTHROPIC_API_KEY`, `ANTHROPIC_MODEL`, `ANTHROPIC_SMALL_FAST_MODEL`, `CLAUDE_CODE_USE_BEDROCK` and `CLAUDE_CODE_USE_VERTEX` are removed from the terminal environment unless `wmux.agents.preserveAuthEnv` is true (cmux parity).

**Job objects** (W1-3): the app creates an instance job at startup; each terminal spawn adds `PROC_THREAD_ATTRIBUTE_JOB_LIST` (second attribute next to the pseudoconsole in `src/Command.zig`) with a per-tab nested job whose only limit is `JOB_OBJECT_LIMIT_BREAKAWAY_OK`. Never `KILL_ON_JOB_CLOSE` (GUI apps launched from a shell must survive tab close). The same jobs give caller identification, per-surface process lists (`JobObjectBasicProcessIdList`) for `top`/`memory` and listening-port attribution (replacing the Toolhelp descendant walk in `meta`). Job assignment failure falls back to ancestry and capability.

### 3.10 Events

- **Bus** (`model/events.zig`, W0-A3; UI thread only):

```zig
pub const Event = struct {
    kind: catalog.Kind,                 // enum built at comptime from wmux_proto/events_catalog.zig
    source: []const u8,                 // "workspace.lifecycle", "window.lifecycle", "socket.v2", "notification.store", …
    window_id: ?Uuid = null, workspace_id: ?Uuid = null, pane_id: ?Uuid = null, surface_id: ?Uuid = null,
    payload: ?Payload = null,           // lazy JSON writer for the stream/log
    automation_origin: ?*const AutomationOrigin = null,
};
pub const Payload = struct { ctx: *const anyopaque, write: *const fn (ctx: *const anyopaque, w: *std.json.Stringify) anyerror!void };
pub fn emit(app: *App, ev: Event) void;  // 1) features.lifecycle.onEvent (sync)  2) session dirty  3) stream/log fan-out
```

- **Emitters.** Lifecycle events come **only** from `model/ops/*` (so UI, shortcuts, CLI, restore and startup each emit exactly once) and from feature stores for their own domains (notification store, sidebar metadata, agents, feed). Socket-sourced events (`surface.input_sent`, `surface.key_sent`, `browser.input`, `notification.*_requested`, …) are emitted by `rpc/dispatch.zig` from a table keyed by method name after a successful reply.
- **Stream** (`rpc/stream.zig`, W2-4): `events.stream {after_seq|after, names|name, categories|category, include_heartbeats}` takes over the connection; frames (`ack`, `event`, `heartbeat`), fields, `resume{after_seq, requested_after_seq, oldest_seq, latest_seq, next_seq, gap}`, filters and catalog exactly as cmux `docs/events.md`. Bounds: replay ring 4,096 events; frame cap 16 KiB (`payload_truncated:true`); 1,024 pending per subscriber then `slow_consumer`; heartbeats every 15 s. JSON is encoded once per event, on the UI thread, only when a subscriber or the log is active; the connection thread writes.
- **Durable log**: `STATE\events\events.jsonl`, rotated at 16 MiB to `.1`; a bounded 1,024-line writer thread drops the oldest disk-only lines under backpressure.
- **Privacy**: titles, bodies and typed text are redacted to `*_length` + `redacted_fields`, as cmux does.

### 3.11 Focus policy

- `focus_intent` is set only on `window.focus`, `workspace.select`, `workspace.next`, `workspace.previous`, `workspace.last`, `surface.focus`, `pane.focus`, `pane.last`, `browser.focus_webview`, `browser.focus`, `browser.tab.switch`, `notification.open`, `notification.jump_to_unread`, and `wmux.debug.*` focus helpers. Other methods preserve focus unless `focus:true`.
- Creation methods default `focus:false`; a tab or pane created without focus is marked unread (manual-unread, ADR-7).
- In-app selection never raises the OS window. To bring wmux forward, an interactive CLI calls `AllowSetForegroundWindow(app_pid)` and sends the request with `focus:true` and `foreground_grant:true`; `app/foreground.zig` activates only while handling such a request within 2 s of its arrival (Windows enforces the grant). Toast/protocol activation is the only other path. Test mode never activates.
- Debug builds assert that a non-`focus_intent` handler without `focus:true` did not change the selected workspace/pane/tab (focus-generation counter compared before/after).

### 3.12 Read plane (W5 optimization)

After each event batch, publish an immutable arena snapshot (windows, workspaces, panes, surfaces summaries) behind an atomic refcounted pointer; polling methods except `surface.read_*` may then run on the `pipe` lane so listings work while the UI thread is busy. Until W5 everything model-reading runs on the `ui` lane with deadlines.

Risks: thread-per-connection resource use (bounded at 64+64); ancestry cost (~1 ms, cached); `cmuxOnly` default breaking external scripts (clear error, documented opt-out, test instances use `automation`); WSL interop processes not in the job (capability token).

---

## ADR-4. CLI front-end

### 4.1 Binaries and install layout

**Decision.** A slim console-subsystem executable built from `src/wmux_cli/main.zig` (imports only std, `wmux_proto` and its own `win.zig` externs; it MUST NOT link the Ghostty terminal, renderer, fonts or apprt). Build artifact `cmux.exe`.

| Installed file | Location | Role |
|---|---|---|
| `cmux.exe` | `INSTALL\cli\` | the CLI; branding follows argv[0] or `WMUX_ARGV0` |
| `wmux.exe` (CLI copy) | `INSTALL\cli\` | byte copy of `cmux.exe` (amendment 2026-10-15, spike S6: `CreateProcessW` and Git Bash do not resolve `.com`). Unambiguous because the GUI `INSTALL\wmux.exe` is never on PATH |
| `wmux.com` | `INSTALL\cli\` | byte copy of `cmux.exe`, kept for cmd/pwsh PATHEXT resolution |
| `cmux`, `wmux` | `INSTALL\cli\posix\` | LF sh launchers for Git Bash and WSL: `WMUX_ARGV0=<name> exec "$(dirname "$0")/../cmux.exe" "$@"`. Kept out of `cli\` (amendment 2026-10-15, spike S4: `where.exe` lists extensionless files first and resolvers that run the first hit fail with error 193); shell integration prepends `cli\posix` only for bash/zsh/WSL shells |
| `wmux.exe` | `INSTALL\` | the GUI app (AUMID, toasts, installer shortcuts); never needs to be on PATH |
| `claude.exe`, `codex.exe` (+ catalog wrappers) | `STATE\shims\<build-id>\agents\` | agent wrappers (ADR-10), hardlinks of `cli\cmux.exe` (copy fallback), created at app start, stale build-ids pruned |
| `tmux.exe` | `STATE\shims\<build-id>\teams\` | tmux compat shim, on PATH only inside team launchers |

Dev builds install the same layout under `zig-out\bin\` (`zig-out\bin\wmux.exe`, `zig-out\bin\cli\cmux.exe`, …). `dist/windows/installer.iss` gains `[Files]` entries for `cli\*` (W1-2) and the `AppUserModelID` on its `[Icons]` entry (W3-7); nothing else changes there.

### 4.2 PATH policy (verified repo constraint)

`dist/windows/installer.iss` carries an ABSOLUTE RULE: the installer must never read or modify PATH or any environment value. Therefore:
1. Inside wmux terminals, the app prepends `INSTALL\cli` (and the agent shims dir) to the child environment (ADR-3.9). This covers the primary use case: agents and scripts running in wmux.
2. Outside wmux, `cmux install-cli [--dir <dir>]` / `uninstall-cli` (W7, feature `install_cli`, also a Settings button) copies small forwarders `cmux.exe`/`wmux.com` into a directory **already on PATH** (default `%LOCALAPPDATA%\Microsoft\WindowsApps`, on the user PATH by default); forwarders locate the real CLI through `HKCU\Software\wmux\InstallDir` and relay with inherited handles. It never edits PATH. Docs describe the manual alternative. Viability of WindowsApps is a W0-D spike.

### 4.3 Dispatch (`wmux_cli/main.zig`)

1. **argv[0] basename** (or `WMUX_ARGV0`): `claude`/`codex`/other catalog wrappers → `wrappers/` (ADR-10.6); `tmux` → `tmux/` (ADR-10.8); `cmux`/`wmux` → grammar.
2. **`+verb` at argv[1]** (legacy wmux): mapped to the cmux command (table 4.11) or, for Ghostty-native actions (`+version +help +list-fonts +list-themes +list-colors +list-actions +list-keybinds +show-config +show-face +validate-config +explain-config +edit-config +crash-report +boo`), relayed to `..\wmux.exe +action …` with inherited handles; exit code propagated. `+hooks` and `+ssh` relay to `wmux.exe` until W3 and W6 replace them.
3. **cmux grammar** (4.4).
4. **`cmux <path>`**: argv[1] is not a command but names an existing path → `app.launch {intent:"open", paths, cwd}` over the launch pipe (no control-socket access needed, cmux contract), launching the app if needed. Command names win over paths.

### 4.4 Grammar and global options (`args.zig`; cmux `docs/cli-contract.md`)

`cmux [--socket <pipe>] [--password <pw>] [--window <id|ref|index>] <command> [options] [--json] [--id-format refs|uuids|both] [--] [args]`

- `--socket`, `--password`, `--window` only before the command; `--json`, `--id-format` before or after it.
- `--` terminates option parsing; tokens after it (including `--help`, `--version`) are payload. Values starting with `+` or `--version` are ordinary text once the command token is consumed (fixes ipc-cli 9.1#9).
- `-h`/`--help`/`help [topic]`, `-v`/`--version`/`version` work without a socket. Help task groups and topics are cmux's (`start agents navigate inspect customize automation browser remote diagnostics`).
- cmux legacy verbs (`new-workspace`, `list-workspaces`, …) print cmux's one-time stderr notice; `CMUX_QUIET=1`/`WMUX_QUIET=1` silence it.

### 4.5 Socket discovery and client behavior (`discovery.zig`, `client.zig`)

Resolution order (first live candidate wins; explicit paths are never rerouted):
1. `--socket`.
2. `WMUX_SOCKET_PATH`/`CMUX_SOCKET_PATH`. If `CMUX_SOCKET` is set non-empty and differs from `CMUX_SOCKET_PATH`, fail before connecting (cmux rule).
3. The marker `STATE\run\instance.json` of the CLI's channel (compiled default; `WMUX_CHANNEL`/`WMUX_TAG` override), trusted only if its pipe's server process belongs to the caller's user SID.
4. The computed control name for the CLI's channel, then for `stable`.
5. Legacy `\\.\pipe\wmux-ipc-<GHOSTTY_PID>`.
6. Enumerated `\\.\pipe\wmux-*` whose server process belongs to the caller's user SID.

Each candidate is probed with `CreateFileW`; `ERROR_PIPE_BUSY` → `WaitNamedPipeW(250)` and retry for up to 2 s. Before sending credentials, `GetNamedPipeServerProcessId` + token SID compare defeats squatting. Messages are cmux's (`cmux: default socket <a> is unavailable; using <b>.`; failure `No live wmux socket found. Tried:` + one indented line per candidate).

- Connect timeout 2 s; response timeout 15 s (`WMUX_CLI_RESPONSE_TIMEOUT_SEC`/`CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC`), overlapped ReadFile with a wait timeout.
- Request ids are random UUIDs; a reply with a different id is an error.
- Retries: `overloaded` (any method) and `rate_limited` (polling methods), honoring `retry_after_ms`, within one deadline; `timeout` only when `retryable`.
- When `CMUX_SOCKET_CAPABILITY`/`WMUX_SOCKET_CAPABILITY` is set, every line is prefixed `_cmux_capability_v1 <token> `. In password mode, `auth.login` is sent lazily (password from `--password`, then `WMUX_SOCKET_PASSWORD`/`CMUX_SOCKET_PASSWORD`).
- `params.caller {workspace_id, surface_id}` is filled from `CMUX_WORKSPACE_ID`/`CMUX_SURFACE_ID` (or `WMUX_` twins) for `identify`, `tree` and `top`.

### 4.6 Target selection and focus default

- Target selection implements cmux's contract once in `targets.zig`: explicit flags; else `CMUX_WORKSPACE_ID` when neither `--workspace` nor `--window` is given; `CMUX_SURFACE_ID` only when neither `--workspace` nor `--window` is given; fail closed on blank or unknown selectors with cmux's exact messages (`No workspace selected: --workspace was blank and CMUX_WORKSPACE_ID is unset`, `Surface handle is blank`, `Invalid surface handle: X (expected UUID, ref like surface:1, or index)`, `Workspace ref not found: X`). The CLI always sends explicit ids, so a background agent acts on its own pane (the largest behavioral gap today).
- Focus default (`focus_default.zig`): interactive = `GetConsoleMode` succeeds on stdin and stdout and no agent marker is set (`CLAUDECODE CLAUDE_CODE CLAUDE_CODE_ENTRYPOINT CODEX_CI CODEX_THREAD_ID CODEX_SESSION_ID OPENCODE OPENCODE_SESSION_ID AI_AGENT CMUX_AGENT_*`). `WMUX_FOCUS_NEW`/`CMUX_FOCUS_NEW` override. Commands always send an explicit `focus`. Interactive focus requests that should raise the window add `foreground_grant:true` after calling `AllowSetForegroundWindow(server_pid)` (ADR-3.11).

### 4.7 Output and exit codes

- Text output matches cmux's text for the same command. Each CLI WP records goldens `test/cli/golden/<command>.txt` derived from cmux's documented formats and CLI source as interface facts (G1).
- `--json` prints the server `result`; `--id-format` is applied client-side by `wmux_proto/idformat.zig` (default refs). `rpc` prints the raw response.
- Errors print `<code>: <message>` plus optional `Reason:`, `What to do:`, `Details:` (allowlisted keys, sanitized to printable characters). On `method_not_found` the CLI calls `system.identify` and prints the version-skew diagnosis (`This CLI:`, `Connected app:`, `Fix:`).
- Exit codes: 0 success, 1 runtime/server error, 2 usage error; launchers, `restore` and `fork` propagate the child's code.
- Console: `WriteConsoleW` when the handle is a console (correct Unicode in conhost), UTF-8 without BOM when redirected; VT processing enabled.

### 4.8 No-socket (offline) commands

`help`, `--help`, `version`, `guide`/`--skill` (embedded guide), `docs [topic]`, `welcome`, `settings path|docs`, `config doctor|check|validate|path|docs|get|set|unset|toggle|cycle|preset`, `socket-status [--json]`, `sessions [list]`, `hooks setup|uninstall|<agent> install|uninstall`, `hooks <agent> <event>` (writes the store even with the app down; prints `{}` outside wmux), `themes list`, `import --dry-run`, `wait-for` (file-based), `review`, `remote-daemon-status`, and every `<command> --help`. `test/cli/probes.ps1` adapts cmux's no-socket probe list with the `cmux`/`wmux` names.

### 4.9 Command spec and families

```zig
// wmux_cli/commands/<family>.zig
pub const commands = [_]CommandSpec{ .{
    .name = "new-workspace", .aliases = &.{}, .group = .start, .hidden = false,
    .usage = "Usage: cmux new-workspace [--name N] [--cwd DIR] [--command TEXT] [--env K=V]... [--env-file F] [--layout L] [--focus [true|false]]",
    .help = @embedFile("../help/new-workspace.txt"),
    .socket = .required,                      // .none | .required | .launch_if_needed
    .legacy_notice = true,
    .run = run,                               // fn (*Ctx) anyerror!u8
} };
```

Families and owners are in Appendix C. Launch-if-needed commands (`open`, `settings`, `shortcuts`, `restore-session`, `new-window`, `cmux <path>`) start `..\wmux.exe` detached with the intent and wait up to 30 s (`CMUX_APP_STARTUP_WAIT_TIMEOUT_SECONDS`/`WMUX_APP_STARTUP_WAIT_TIMEOUT_SECONDS` may shorten it) for the launch/control pipe.

### 4.10 `wmux.exe` argv routing (`src/main_ghostty.zig`, edited once by W1-2)

1. First token is a Ghostty-native `+action` → Ghostty CLI in-process (unchanged).
2. First token is a wmux/cmux command, a legacy wmux `+verb`, or a global CLI option → relay: if std handles are null, `AttachConsole(ATTACH_PARENT_PROCESS)` first; spawn `<exe dir>\cli\cmux.exe` with the same argv and inherited handles; wait; exit with its code. (Piped contexts work; an interactive cmd still does not wait for a GUI process — documented, and the reason `cli\` exists.)
3. Otherwise start the app through single-instance forwarding (ADR-3.1). `--new-window` and jump-list tasks use the same path.

The wmux-specific IPC client verbs in `src/cli/` (`workspace tab send notify surface split status log read_screen capture_pane session browser new_window toggle_quick_terminal agent_ipc`) are deleted by W1-2 once the relay works; `hooks.zig` (W3-3) and `ssh.zig` (W6) are deleted when replaced.

### 4.11 Legacy `+verb` mapping (both binaries)

| Legacy | cmux command |
|---|---|
| `+workspace list\|new\|select\|close` | `list-workspaces` \| `new-workspace` (`--worktree/--repo` kept as wmux extensions) \| `select-workspace` \| `close-workspace` |
| `+tab list\|new\|select\|close` | `list-pane-surfaces` \| `new-surface` \| `focus-panel` \| `close-surface` |
| `+surface list\|focus` | `list-panels` \| `focus-panel` |
| `+split <dir>` | `new-split <dir>` |
| `+send <text> [--enter]` | `send` (`--enter` appends `\r`) |
| `+notify ring\|clear\|next\|toggle-read\|mark-oldest-next` | `wmux attention ring\|clear` (`wmux.attention.set`) \| `jump-to-unread` \| `wmux notification toggle-unread` \| `wmux notification mark-oldest-jump` |
| `+status set\|progress` | `set-status` \| `set-progress` |
| `+log` | `log` |
| `+read-screen`, `+capture-pane` | `read-screen`, `capture-pane` |
| `+browser <sub>` | `browser <sub>` |
| `+session capture\|resume\|show\|save\|restore` | `surface-resume set` \| `wmux session resume` \| `sessions` \| `wmux session save` \| `restore-session` |
| `+hooks setup` | `hooks setup` |
| `+ssh` | `ssh` (W6; relayed to `wmux.exe +ssh` until then) |
| `+new-window`, `+toggle-quick-terminal` | `new-window`, `wmux quick-terminal toggle` |

Old flag spellings (`--workspace I` as an index, `--pane P`, `--tab T`) stay accepted. No new `+verbs` are ever added. wmux-only CLI commands live under the `wmux` namespace command (`cmux wmux <sub>` / `wmux wmux <sub>`, aliased as top-level `wmux <sub>` when the binary is invoked as `wmux` and `<sub>` is not a cmux command).

Risks: AV heuristics on `.com` (sign both; fallback name `wmux-cli.exe`); version skew between CLI and app (skew diagnosis, shipped together); hardlinks across volumes (copy fallback).

---

## ADR-5. Configuration and the Settings window

### 5.1 Files and precedence (lowest → highest)

| # | Layer | Path |
|---|---|---|
| 1 | built-in defaults | `wmux_proto/settings/specs/*.zig` |
| 2 | legacy Ghostty keys | only keys **explicitly set** in the user's Ghostty config (detected via `Config._replay_steps`, never via default values): `window-show-sidebar`→`wmux.sidebar.visible`, `window-sidebar-width`→`wmux.sidebar.width`, `sidebar-metadata`→`sidebar.hideAllDetails` (inverted), `window-show-right-sidebar`→`wmux.rightSidebar.visible`, `window-right-sidebar-width`→`wmux.rightSidebar.width`, `socket-control`→`automation.socketControlMode`, `desktop-notifications`→`wmux.notifications.desktop` (keys that cmux's schema lacks live under `wmux.`, G2) |
| 3 | cmux global (shared dotfiles) | `%XDG_CONFIG_HOME%\cmux\cmux.json`, else `%USERPROFILE%\.config\cmux\cmux.json`. Read-only by default. |
| 4 | wmux global (primary) | `%WMUX_CONFIG_DIR%\wmux.json`, else `%XDG_CONFIG_HOME%\wmux\wmux.json`, else `%USERPROFILE%\.config\wmux\wmux.json`. All writers target this file. |
| 5 | packs | `packs: [...]` local paths, resolved before the file that lists them; a directory resolves to `wmux.pack.json`, then `cmux.pack.json` |
| 6 | project | upward from the workspace cwd: `.wmux\wmux.json`, `wmux.json`, `.cmux\cmux.json`, `cmux.json`; only project-scoped keys (cmux `x-cmux-scopes`); id-keyed entries override global ones; project actions, commands and hooks require trust (ADR-6.7, W4-7) |
| 7 | managed policy | `HKLM\Software\Policies\wmux\<setting path>`, then `HKCU\…`; locks the Settings row, CLI refuses writes; re-read at startup, on `WM_SETTINGCHANGE("Policy")` and every 60 s |

A `wmux.json` key always beats the same key in `cmux.json`, so a macOS-authored shared `cmux.json` can be patched per machine. `wmux.json` uses the cmux schema plus wmux extensions under the top-level `wmux` key and Windows-literal shortcut strokes; the shared `cmux.json` stays valid on the Mac because wmux writes there only when asked (`config set --file cmux`). The Settings UI writes `wmux.json` directly (no separate preferences store; Appendix E).

### 5.2 Spec registry and typed access

```zig
// wmux_proto/settings/spec.zig
pub const Spec = struct {
    path: [:0]const u8,                                  // "sidebar.showPorts"
    ty: union(enum) { boolean, integer: struct { min: i64, max: i64 }, number: struct { min: f64, max: f64 },
                      string: struct { pattern: ?[]const u8 = null }, enumeration: []const []const u8,
                      color, path, string_list, object, strokes },
    default: []const u8,                                 // JSON literal, validated at comptime
    scope: enum { global, project, both } = .global,
    section: []const u8,                                 // Settings UI section id (cmux raw ids + "windows")
    label: []const u8, doc: []const u8, keywords: []const []const u8 = &.{},
    apply: enum { live, restart } = .live,
    cmux_compat: bool = true,                            // false for keys under "wmux."
    ghostty_override: ?[]const u8 = null,                // e.g. "copy-on-select" for terminal.copyOnSelect
    policy_lockable: bool = true,
    palette_toggle: bool = false,                        // generates "Enable/Disable <label>" palette entries
};
// app side (settings/api.zig): comptime-checked typed reads; an unknown path or wrong type is a compile error
const show_ports = settings.get(app, "sidebar.showPorts");   // bool
```

`app.settings` is a `*const Snapshot` swapped atomically on reload and refcounted for worker threads. Until W1-4 lands, `settings.get` returns spec defaults, so W1 WPs can already declare and read their keys.

### 5.3 Validation and errors

- JSONC (comments, trailing commas) via `wmux_proto/jsonc.zig`. Root keys `$schema` (wmux schema URL or cmux's), `schemaVersion` (≥1; newer parses best-effort with a warning), `packs`.
- Parse error in a file → keep the last good resolved settings, show a non-modal notice (`ui/notice.zig`) with the first three errors and "Open", add a palette row "wmux.json schema error".
- Type/range error on a key → that key falls back to the next lower layer; `config doctor` reports an error.
- Known cmux keys that wmux does not implement yet or that are macOS-only (`wmux_proto/settings/cmux_known_keys.zig`, a list of key paths = interface facts) → `config doctor` info "ignored on Windows" / "not yet supported". `mobile` and `cloud` sections are accepted and ignored.
- Unknown keys → `config doctor` warning; never fatal.

### 5.4 Live reload (`settings/watcher.zig`, W1-4)

One worker thread with overlapped `ReadDirectoryChangesW` per distinct directory: the JSON directories, the Ghostty config files and `config-file` includes, theme directories, `sidebars\` and the project directories of open workspaces. Symlinks resolve through `GetFinalPathNameByHandleW`. Debounce 300 ms; content-hash to skip no-ops and self-writes; parse/validate on the worker; post a task; the UI swaps the snapshot, calls every feature's `onSettingsChanged(diff)` and emits `config.reloaded`. Ghostty reloads keep today's `reload_config` path; Ghostty diagnostics feed the same notice.

### 5.5 Ghostty interplay

- Ghostty config loading is unchanged (`%XDG_CONFIG_HOME%\ghostty\…`, else `%LOCALAPPDATA%\ghostty\config.ghostty`, plus includes). It is followed by the **wmux overlay** `CONFIG\config.ghostty` (written by `themes set`, `import`, Settings font/theme controls) and then the generated **JSON overrides** file `STATE\run\settings-overrides.ghostty`: for every explicitly set JSON key with `ghostty_override` (e.g. `terminal.copyOnSelect`→`copy-on-select`, `terminal.confirmUnsafePaste`→`clipboard-paste-protection`) the settings layer writes the Ghostty line. Unset JSON keys defer to Ghostty.
- New wmux features never add Ghostty config keys (G8). Existing wmux Ghostty keys remain legacy inputs (§5.1 row 2); `config doctor` prints `deprecated Ghostty key X; set Y in wmux.json`.

### 5.6 `config` CLI (offline, W1-4)

`config get|set|unset|toggle|cycle|preset|doctor|check|validate|path|docs [--json]` use the same specs and `wmux_proto/json_edit.zig`, a lossless span editor (tokenize with spans, replace or insert value nodes, infer sibling indentation, preserve comments and key order, validate the whole result first, reject only issues the edit introduced). Writes take a sidecar lock `<file>.wmux-write.lock` (`CREATE_ALWAYS`, share 0, `FILE_FLAG_DELETE_ON_CLOSE`) and replace atomically (temp + `MoveFileExW(REPLACE_EXISTING|WRITE_THROUGH)`). `--preview`, `--expect-revision` and receipts/undo follow cmux `docs/config-transactions.md`. `config get --json` reports `source: default|ghostty|cmux.json|wmux.json|project|policy`. `config reload` (socket) → `wmux.config.reload`. Legacy shorthands `sidebar-font-size`, `surface-tab-bar-font-size` map to their JSON paths. `zig build settings-schema` emits `docs/wmux/schema/wmux.schema.json` (committed; a `test-fast` golden test fails when stale; installed to `SHARE\wmux\schema\`).

### 5.7 Policy

`settings/policy.zig` (W1-4) reads `HKLM` then `HKCU` `Software\Policies\wmux` values named by setting path (`REG_SZ` JSON literal, or `REG_DWORD` for booleans/integers) into the top layer. W1-4 implements the generic mechanism; the ADMX template ships in W7 (`policy` feature).

### 5.8 Settings window: WebView2-hosted local web UI

**Decision.** `features/settings_ui/` (W4-4) opens a top-level window hosting a `WebPanel` of kind `settings` (`src/web/settings/`), rendered generically from the spec registry export: sections (cmux raw ids `app themes terminal textBox sidebarAppearance automation browser browserImport globalHotkey keyboardShortcuts workspaceColors settingsJSON reset` + a Windows-only `windows` section: CLI tools install, toast test, default shell, "Open in wmux" Explorer entry), search, per-key source badges, policy locks, a shortcut recorder and theme swatches. Account, mobile, cloud, devices and networking sections are omitted.

Justification: ~400 keys with search, enums, colors, lists and validation would be several times the code in hand-built Win32 dialogs with weak DPI/dark-mode support; WebView2 gives UIA, IME, high-DPI, forced-colors and text search; the runtime is already a dependency; the framework is needed for ten other panels; a feature's settings appear with zero UI work (preserves "new files only"). Costs: ~30–60 MB while open and ~300 ms first open (mitigated by pre-warming the environment 5 s after launch). Without the runtime, `openSettings` opens `wmux.json` in the default editor with a notice.

Bridge methods (allowlisted for kind `settings` only): `settings.open {target}` (cmux name; `cmux settings <target>` deep-links), `wmux.settings.schema`, `wmux.settings.get_effective`, `wmux.settings.set`, `wmux.settings.unset`, `wmux.shortcuts.list`, `wmux.shortcuts.validate`, `wmux.shortcuts.set`. While the recorder captures keys, the page sends `panel.key_capture {on}` and the KeyRouter skips that controller.

Risks: lossless editor edge cases (golden corpus + property tests: random edit sequences round-trip, comments and order survive); two global files confuse users (`config path` and `config get --json` show the source per key).

---

## ADR-6. Web panel framework

### Decision

A third tab-content kind `web: *WebPanel` hosts any bundled local web app. Panel kinds register through `features/<id>/panels.zig`. Content loads from per-app virtual hosts. The JS↔native bridge carries the v2 envelope, dispatched through the RPC registry under a per-kind allowlist. Everything rich that is neither a terminal nor a user browser tab is a web panel; latency- or focus-critical chrome stays native (sidebar, tab bars, command palette, find bar, TextBox composer, rename edits, overlays).

### 6.1 Model and host integration

```zig
// model/TabContent.zig (all variants pre-added in W0-A3 with stub types; W1-6 implements WebPanel; frozen)
pub const TabContent = union(enum) {
    terminal: *Surface, browser: *BrowserPane, web: *WebPanel, placeholder: Placeholder,   // placeholder = hibernated/lazy
    pub fn hwnd(self: TabContent) ?HWND;
    pub fn setBounds(self: TabContent, r: Rect) void;
    pub fn setVisible(self: TabContent, v: bool) void;
    pub fn focus(self: TabContent) void;
    pub fn kindName(self: TabContent) []const u8;          // "terminal" | "browser" | "markdown" | … (event payload "kind")
    pub fn snapshot(self: TabContent, w: *std.json.Stringify) !void;
};
```

Host placements (one host HWND class `WmuxPanelHost`): (1) pane tab, laid out like `BrowserPane`; (2) right-sidebar mode content; (3) owned popup (notifications popover); (4) top-level `PanelHostWindow` (Settings, Task Manager, About). Creation goes through `model/ops/surface.zig: create(pane, .{ .web = .{ .kind = "markdown", .params = … } }, opts)`.

### 6.2 PanelKind (`web/PanelKind.zig`)

```zig
pub const PanelKind = struct {
    id: [:0]const u8,                                  // "markdown"
    app: [:0]const u8,                                 // asset dir under SHARE\wmux\web\ (usually == id)
    title: *const fn (*WebPanel) []const u8,
    allow: []const []const u8,                         // bridge-callable methods (exact or "prefix.*"); "panel.*" implicit
    events: []const []const u8 = &.{},                 // event categories pushed to the page
    file_access: enum { none, own_file_dir, workspace_root } = .none,
    network: enum { none, consent_remote_images } = .none,
    placements: struct { tab: bool = true, right_sidebar: bool = false, popup: bool = false, window: bool = false } = .{},
    singleton: enum { none, workspace, window, app } = .none,
    create: *const fn (*WebPanel, params: std.json.Value) anyerror!void,
    destroy: ?*const fn (*WebPanel) void = null,
    snapshot: ?*const fn (*WebPanel, *std.json.Stringify) anyerror!void = null,   // session + recently closed
    restore: ?*const fn (*WebPanel, std.json.Value) anyerror!void = null,
    on_message: ?*const fn (*WebPanel, *rpc.Ctx) rpc.Error!bool = null,          // "panel.<kind>.*"; false = unhandled
    read_selection: ?*const fn (*WebPanel, *rpc.Ctx) rpc.Error!void = null,      // surface.read_selection
    is_dirty: ?*const fn (*WebPanel) bool = null,
    page_keymap: []const []const u8 = &.{},            // action ids whose bare keys the page implements (diff j/k …)
    suspend_after_ms: u32 = 300_000,
};
pub const WebPanel = struct { tab: *Tab, kind: *const PanelKind, host: ?*WebHost, state_json: ?[]u8, title: []u8, kind_state: ?*anyopaque };
```

### 6.3 WebView2 environment and profiles (`web/env.zig`)

- **One** environment per user-data folder `STATE\webview2\` (moved once by rename from `%LOCALAPPDATA%\ghostty\webview2` when not locked). App panels use the controller profile **`wmux-ui`** (`ICoreWebView2Environment10::CreateCoreWebView2ControllerOptions` + `put_ProfileName`); user browser panes use `default` (named browser profiles in W5 are further profiles). Storage is isolated; the browser process is shared (memory).
- Remote workspaces (W6) get their own environment per route because the proxy is an environment argument.
- Minimum runtime 1.0.1185 (`GetAvailableCoreWebView2BrowserVersionString`); below it panels degrade to fallbacks (open externally / notice). Environment failure is no longer sticky: creation is retried on the next panel.

### 6.4 Assets, virtual hosts and file access

- Sources: `src/web/<app>/` (index.html + ES modules), `src/web/_shared/` (`wmux-bridge.js`, `theme.css`, small web components), `src/web/_vendor/<lib>@<ver>/` (prebuilt minified bundles + LICENSE + SHA256SUMS listed in `_vendor/README.md`: marked, DOMPurify, highlight.js, github-markdown-css, mermaid (lazy), vega/vega-lite, CodeMirror 6 prebuilt ESM, a permissive diff renderer). **No JS toolchain in the build**: wmux-authored JS is plain ES2022; vendored bundles are produced offline (WSL/Node allowed) and committed. `zig build` installs `src/web/**` to `SHARE\wmux\web\`. `WMUX_WEB_DIR=<repo>\src\web` serves live sources in dev.
- Virtual host per app: `https://<app>.wmux.example/` mapped with `ICoreWebView2_3::SetVirtualHostNameToFolderMapping(host, SHARE\wmux\web, DENY_CORS)`; entry `https://<app>.wmux.example/<app>/index.html`; shared code via relative `../_shared/` and `../_vendor/` (same origin). Mappings exist only on panel webviews, never on browser panes. `.example` never resolves (avoid `.local`).
- User files (`file_access = own_file_dir`): a per-panel token host `https://f-<16hex>.wmux.example/` mapped to the file's directory (HTTP Range for media for free), removed on close. Synthesized data (diffs, listings): `https://d-<16hex>.wmux.example/…` served from a native token registry via `AddWebResourceRequestedFilter` + `CreateWebResourceResponse`, with file reads on a worker using the deferral pattern. Pages never receive raw filesystem paths beyond what native chooses to show; the diff viewer needs no local HTTP server (Appendix E).

### 6.5 Bridge protocol (`web/bridge.zig`, `src/web/_shared/wmux-bridge.js`)

```
page → native   {"v":1,"id":"c17","method":"workspace.list","params":{}}           (id omitted = fire-and-forget)
native → page   {"v":1,"id":"c17","ok":true,"result":{…}} | {"v":1,"id":"c17","ok":false,"error":{"code","message"}}
native → page   {"v":1,"event":"panel.init","payload":{"kind","surface_id","params","state","theme","keymap","settings"}}
                {"v":1,"event":"theme","payload":{…}}   {"v":1,"event":"cmux.event","payload":<events frame>}
JS API          wmux.ready(); wmux.call(method, params) → Promise; wmux.on(event, cb); cmux(method, params) alias
```

- Native identifies the sender **by the controller that raised `WebMessageReceived`**; JS-supplied identity is never trusted. Dispatch: `PanelKind.on_message` first, then the RPC registry with `Origin.in_process{.web_panel}`; methods outside the kind's allowlist → `forbidden`. Browser-pane controllers never register `WebMessageReceived`.
- Panel-local methods: `panel.ready`, `panel.set_title`, `panel.set_dirty`, `panel.state_changed {state}` (≤64 KiB, kept for the snapshot), `panel.read_file`/`panel.write_file` (own file only, atomic, encoding-preserving), `panel.watch_file`, `panel.open_external {url}`, `panel.open_in_browser {url}`, `panel.open_file {path}` (file-open router), `panel.clipboard_write {text, html?}` (only within 2 s of a user gesture), `panel.request_focus`, `panel.key_capture {on}`, `panel.subscribe {categories}`, `panel.notify {title, body}`.

### 6.6 Theming (`web/theme.zig`)

On `panel.init` and on every config change native pushes `theme`: Ghostty `background`, `foreground`, `palette[0..15]`, `cursor`, `selection`, font family and size (px at the current DPI), background opacity, `scheme` (`dark`/`light` by luminance), `high_contrast` (`SPI_GETHIGHCONTRAST`), the wmux accent and the sidebar colors. `_shared/theme.css` maps them to `--wmux-*` CSS variables. `ICoreWebView2Controller2::put_DefaultBackgroundColor` = terminal background (no white flash).

### 6.7 Security model (deny by default)

- Navigation locked to the panel's origin: `NavigationStarting` cancels anything else and routes it by policy (wmux browser tab, OS browser, or blocked); `NewWindowRequested` is always handled and never opens a top-level popup.
- CSP meta on every page: `default-src 'self'; script-src 'self'; connect-src 'self' https://d-*.wmux.example; img-src 'self' data: https://*.wmux.example; object-src 'none'`. Remote markdown images only after per-host consent stored in `STATE\trust\remote-images.json` (CSP rewritten for that panel).
- Per panel webview: `AreHostObjectsAllowed=false`, `AreDefaultContextMenusEnabled=false` (pages draw their own), `IsStatusBarEnabled=false`, `AreBrowserAcceleratorKeysEnabled=false` (`Settings3`), password autosave and general autofill off (`Settings4`), DevTools only in Debug builds, test mode or with `WMUX_WEB_DEVTOOLS=1`.
- Untrusted content (markdown, HTML preview) renders through DOMPurify; `.html` file previews open in a **browser** pane, never in a panel.
- Project trust (`STATE\trust\projects.json`, W4-7): project-scoped actions, commands, notification hooks and custom sidebars run only after the user approves the project path once.
- `ProcessFailed`: show a "reload" overlay, recreate, restore `state_json`.

### 6.8 Keyboard, focus, DPI

`ICoreWebView2Controller::AcceleratorKeyPressed` calls the KeyRouter first (ADR-8); consumed keys get `put_Handled(TRUE)`. Bare-key panel shortcuts are implemented in the page from `panel.init.keymap`. `GotFocus`/`LostFocus` update model focus (LostFocus newly wired). `ICoreWebView2Controller3::put_ShouldDetectMonitorScaleChanges(TRUE)`; bounds are set in physical pixels on DPI change.

### 6.9 Lifecycle, memory, session

Controllers are created lazily on first show (hidden tabs cost nothing); a hidden panel is `TrySuspend`ed after `suspend_after_ms`; `WebHost` keeps today's `BrowserPane` in-flight-ref and zombie discipline; the notifications popover keeps one warm hidden host. The session stores `{kind:"web", app, params, state}` (ADR-9) and restores lazily. Task Manager (W5) attributes WebView2 processes per panel via `BrowserProcessId` + process tree.

### 6.10 `platform/webview2.zig` bindings completed once by W1-6

Replace padded slots (same index, slot comments, comptime slot-count asserts) and add interfaces. `ICoreWebView2`: `get_Settings`, `NavigationStarting`, `SourceChanged`, `HistoryChanged`, `ContentLoading`, `ProcessFailed`, `AddScriptToExecuteOnDocumentCreated`, `CapturePreview`, `WebMessageReceived`, `PostWebMessageAsJson`, `BrowserProcessId`, `CanGoBack`/`CanGoForward`, `NewWindowRequested`, `ContainsFullScreenElement`, `WebResourceRequested` + filter, `WindowCloseRequested`, `OpenDevToolsWindow`, `ScriptDialogOpening`, `PermissionRequested`. Newer interfaces: `ICoreWebView2_2` (DOMContentLoaded, CookieManager, Environment), `_3` (TrySuspend, Resume, SetVirtualHostNameToFolderMapping), `_4` (DownloadStarting), `_10` (BasicAuthenticationRequested), `_13` (Profile), `_16` (Print); `ICoreWebView2Controller2/3/4`; `ICoreWebView2Settings`–`Settings6`; `ICoreWebView2Environment2/10` + `ControllerOptions`; `ICoreWebView2EnvironmentOptions` (`AdditionalBrowserArguments`, language); a generic `qi(comptime T, obj) ?*T` using `T.IID`. COM rule: AddRef any borrowed interface that outlives a callback (fixes browser B1). After W1-6 the file is frozen; later needs go through a CCR.

### 6.11 Panel kinds and owners

`about` (W1-6: demo + third-party licenses), `markdown` (W4-1), `filepreview` (W4-2: CodeMirror text/code editor, image, PDF via Chromium's viewer, audio/video, Shell preview-handler fallback), `diff` (W4-3), `settings` (W4-4), `notifications` popover + pane (W3-8), `files` and `find` (W4-8), `todo`, `feed`, `vault`, `task_manager`, `custom_sidebar` runtime, `agent_chat` (W5), `welcome` (W7).

Risks: renderer memory (~20–40 MB per active panel app; lazy creation, suspension, one profile, one shared browser process); focus ping-pong between HWND and WebView2 (explicit `MoveFocus` + router hook); hand-written vtable errors (slot asserts + an e2e that exercises every bound method).

---

## ADR-7. Notifications

### 7.1 Record and store (`features/notifications/store.zig`, pure, unit-tested)

```zig
pub const Record = struct {
    id: Uuid, workspace: Uuid, surface: ?Uuid,
    title: []const u8, subtitle: []const u8, body: []const u8,          // owned, uncapped (UI truncates)
    created_at_ms: i64, read: bool,
    origin: union(enum) { local, ssh_relay: Uuid },
    agent: ?struct { kind: []const u8, category: enum { turn_complete, needs_permission, idle_reminder, other },
                     session_id: ?[]const u8, is_subagent: bool, pending_background: bool } = null,
    correlation_key: ?Uuid = null,
    click_action: ?union(enum) { open_file: []const u8, open_url: []const u8, reply } = null,
    reply_shape: enum { none, text } = .none,
    scroll_anchor: ?ScreenAnchor = null,
    effects: Effects = .{},                                              // desktop, sound, command, pane_flash, mark_unread, reorder
};
```

- Newest first. A new record **replaces** earlier records for the same (workspace, surface), unless it carries a `correlation_key`, in which case only records with the same key on that surface are replaced. Replaced records' toasts are withdrawn and the target's manual-unread marker is cleared.
- Records for muted workspaces are dropped. History cap 500 (`wmux.notifications.historyLimit`), dropping the oldest **read** records first. Dismissed ids are tombstoned so restore never resurrects them.
- Bell, child exit and sidebar `log` lines are **not** records (they set attention/tab status or write the sidebar log), so the badge counts notifications only (fixes the conflated counters).

### 7.2 Unread model and auto-read

Unread sources: unread records, manual workspace/surface marks, restored marks, and the focused-read indicator. One query API (`globalUnreadCount`, `workspaceUnreadCount`, `surfaceHasIndicator`) drives the sidebar badge, pane ring (terminal **and** browser/web panes), tab dot, taskbar overlay and tray badge (fixes the two diverging counters). Auto-read per cmux: focusing a pane marks that pane's records read; selecting a workspace marks the workspace's own (surface-less) records read; typing marks read; "Mark Workspace as Read" clears everything in the workspace.

### 7.3 Ingestion

- **OSC** (core change owned by W2-5 in `src/apprt/surface.zig`, `src/termio/stream_handler.zig`, `src/Surface.zig`, `src/terminal/osc/parsers/kitty_notification.zig`): OSC 777 `notify;title;body`; OSC 9 `<text>` excluding `9;4` (progress → sidebar/taskbar, W2-6) and `9;9` (cwd); OSC 99 kitty (`;`/`:` payload separators, `p=subtitle`, `i=` chunk reassembly per surface, base64, `p=?` queries ignored). Payloads are heap-allocated (title/subtitle ≤ 1 KiB, body ≤ 8 KiB) instead of the 63/255-unit inline buffers; the core's app-global 1/s limiter is replaced by per-surface coalescing (identical title+body within 1 s collapse).
- **Ingress FIFO** at the apprt: 256 entries, drop-oldest, entries `{surface uuid, title, subtitle, body, kitty{id, done}, origin}`; the workspace is resolved at delivery time (a moved pane notifies its new workspace). Empty title → workspace title → "Terminal".
- Raw OSC notifications from a surface with a live hook-integrated agent session are suppressed (cmux behavior; the hook bridge covers them). The `@ghostty-attention:ring|clear` sentinel stays as a wmux extension mapped to manual-unread.
- **Other entry points**: `notification.create*` (CLI `notify`), agent hooks (ADR-10), automations, the remote relay (`origin = ssh_relay`).

### 7.4 Delivery pipeline (`features/notifications/deliver.zig`)

Ordered: (1) mute check; (2) cooldown keys; (3) `notifications.hooks` (global, then project with trust; `hooksMode: "replace"` honored; JSON on stdin, JSON patch on stdout; worker thread, 20 s timeout, 1 MiB cap; failure → default delivery + throttled alert); (4) effects `{record, markUnread, reorderWorkspace, desktop, sound, command, paneFlash}` (`--desktop false` arrives as `effects.desktop=false`); (5) focus suppression; (6) delivery; (7) `notifications.command` via `wmux.notifications.commandShell` (`cmd` default → `cmd.exe /d /s /c`, or `pwsh -NoProfile -Command`), `CREATE_NO_WINDOW`, `CMUX_NOTIFICATION_*` + `WMUX_` env, ≤32 concurrent, kill-on-close job with a 300 s limit, output discarded.

**Focus suppression** (cmux): "app focused" = the foreground window belongs to our process. Default: suppress the desktop banner only when the record targets the exact focused surface (app focused, its workspace selected in that window, its tab focused); such records are stored read with the focused-read indicator and a flash, and play a sound only with `notifications.soundWhenFocused`. `notifications.suppressWhenAppFocused` (opt-in) suppresses all banners while wmux is foreground. `notifications.suppressOnlyFocusedSurface` controls the auto-withdraw scope (§7.5).

### 7.5 Desktop delivery (`features/toasts/`, `platform/winrt/`, W3-7)

- **AUMID**: `wmux.app` (stable) / `wmux.app.<channel>`. At startup, before the first window, `SetCurrentProcessExplicitAppUserModelID`. Registration (never in test mode): `HKCU\Software\Classes\AppUserModelId\<AUMID>` (`DisplayName`, `IconUri` = `SHARE\wmux\icons\toast.png`); the installer's Start-menu shortcut also carries `System.AppUserModel.ID` (Inno `[Icons] AppUserModelID`).
- **Protocol activation (primary click path)**: `HKCU\Software\Classes\wmux` (`URL Protocol`, `shell\open\command = "<INSTALL>\wmux.exe" "%1"`); non-stable channels use `wmux-<channel>`; stable also registers `cmux:` when no other handler owns it. Clicking launches `wmux.exe wmux://notification/open?id=<uuid>`, which forwards `app.launch {intent:"uri"}` over the launch pipe, calls `AllowSetForegroundWindow(server_pid)` and exits; the instance runs `notification.open` (focus intent + foreground). If no instance runs, the process becomes the app, restores the session and then opens the record if it still exists. The same handler serves deep links (`features/deeplinks`).
- **Toasts**: hand-written WinRT ABI (`RoGetActivationFactory`, `WindowsCreateStringReference`, IInspectable vtables): `IToastNotificationManagerStatics::CreateToastNotifierWithId(aumid)`, `XmlDocument.LoadXml`, `IToastNotificationFactory`; `IToastNotification2` `Tag` = record UUID (36 chars ≤ the 64-char limit), `Group` = workspace UUID. Template: `launch="wmux://notification/open?id=…" activationType="protocol"`, text lines title|workspace|"wmux", subtitle, body; actions "Show" (protocol) and, when `reply_shape = text`, "Reply" with an input box (`activationType="foreground"` through the COM activator); feed decisions up to 5 protocol buttons; always `<audio silent="true"/>` (wmux plays sounds itself).
- **COM activator (Reply only)**: `INotificationActivationCallback` via `CoRegisterClassObject(CLSCTX_LOCAL_SERVER, REGCLS_MULTIPLEUSE)`, `HKCU\Software\Classes\CLSID\{CLSID}\LocalServer32 = "<INSTALL>\wmux.exe" -ToastActivated` and `CustomActivator` on the AUMID key. If HKCU COM registration is blocked by policy, Reply buttons are omitted (protocol clicks still work).
- **Withdraw**: `ToastNotificationHistory.Remove(tag, group, aumid)` when a record is read, replaced, dismissed or cleared; `RemoveGroup(workspace)` on workspace select unless `notifications.suppressOnlyFocusedSurface`.
- **Fallback**: when toasts are unavailable (`IToastNotifier::get_Setting` ≠ Enabled, WinRT activation failure, Server SKUs), a single persistent tray icon (`features/tray`, `NOTIFYICON_VERSION_4`) shows a balloon, with a one-time notice. Throwaway per-notification tray icons are removed. `wmux.notifications.desktopBackend = auto|toast|balloon|none`.
- **Test mode**: nothing is registered or shown; deliveries append to `WMUX_TEST_TOAST_SINK` (JSONL) and are listed by `wmux.debug.toasts.list`.

### 7.6 Sounds

Self-played so banner policy and sound policy stay consistent. `notifications.sound` ∈ `default | none | custom_file | <cmux preset name> | windows:<event>`; presets map to Windows sound events played with `PlaySoundW(name, NULL, SND_ALIAS|SND_ASYNC|SND_NODEFAULT)` (table in `features/notifications/sound.zig`: `default`→`Notification.Default`, `Glass`→`Notification.IM`, `Ping`→`Notification.SMS`, `Hero`→`Notification.Reminder`, `Submarine`→`Notification.Looping.Call`, others → `Notification.Default`); `.wav` custom files via `SND_FILENAME`, `.mp3`/`.m4a` via MCI. Skipped when `SHQueryUserNotificationState` ≠ `QUNS_ACCEPTS_NOTIFICATIONS` (Focus Assist, presentation mode). `notifications.soundOverrides` per category honored.

### 7.7 UI surfaces

Sidebar unread badge + latest-notification preview (row contributors, ADR-11); per-pane `FlashOverlay` (pooled; color and double-blink settings) and the attention ring for terminal, browser and web panes; taskbar overlay count (existing `taskbar.zig`) and taskbar progress from OSC 9;4 (`ITaskbarList3::SetProgressValue/State` get real vtable slots in W2-6); `FlashWindowEx` only with `wmux.notifications.flashTaskbar`. Notifications popover = `notifications` web panel in an owned popup anchored to the sidebar footer bell (`showNotifications`), with cmux's header, rows, context menu and persisted size; the same app as a pane tab.

### 7.8 RPC, CLI, events

Methods (cmux names): `notification.create`, `.create_for_caller`, `.create_for_surface`, `.create_for_target`, `.list`, `.clear`, `.dismiss`, `.mark_read`, `.open`, `.jump_to_unread`, `notification.feed.*` (W5), plus `app.focus_override.set` and `app.simulate_active` (tests). wmux extras: `wmux.attention.set {on}` (legacy ring/clear), `wmux.notification.toggle_unread`, `wmux.notification.mark_oldest_jump`. CLI: `notify --title --subtitle --body --workspace --surface --desktop <bool> --clear --reply` (prints `OK notification:<uuid>`; strict cmux argument validation), `list-notifications`, `dismiss-notification [--all-read]`, `mark-notification-read`, `open-notification`, `jump-to-unread`, `clear-notifications`, `trigger-flash`. Events: the `notification.*` set of the cmux catalog, emitted by the store (records) and by dispatch (`*_requested`).

### 7.9 Persistence

The notifications `ext` section per workspace saves unread records (latest 100 per workspace), manual marks and tombstones; restored marks appear as restored-unread.

Risks: WinRT ABI binding errors (IID tests, a real-desktop smoke in the W0-D spike, test sink in CI); Group Policy disabling toasts (detected; balloon fallback with notice); Focus Assist hides banners (records still land, matching cmux).

---

## ADR-8. Keyboard shortcuts and actions

### 8.1 Catalog and handlers

- **Catalog** `wmux_proto/actions_catalog.zig` (pure data, complete in W0-A3 from Appendix A; shared-appendable):

```zig
pub const Entry = struct {
    id: []const u8,                          // cmux id ("splitRight", "resize-pane-left", "toggleFileExplorer") or "wmux.<name>"
    title: []const u8,                       // English label (localized in W7)
    category: Category,                      // app window workspace surface pane notification browser find viewer sidebar canvas agent terminal
    keys: []const []const u8 = &.{},         // Windows defaults (grammar 8.3); a chord is "ctrl+b c"
    when: ?[]const u8 = null,                // built-in context clause
    numbered: bool = false,                  // 1–9 family; 9 = last
    performable: bool = false,               // key passes through when the handler returns .not_applicable
    priority_routing: bool = false,          // wins its context outright (right-sidebar digits)
    palette: bool = true,
    availability: enum { supported, not_applicable } = .supported,   // cloud/simulator/mac-only ids: accepted in config, inert
};
```

- **Handlers** live in features: `pub const handlers = [_]input.ActionHandler{ .{ .id = "splitRight", .run = splitRight } };` with `fn (ctx: *input.ActionCtx) input.ActionResult`, `ActionResult = enum { handled, not_applicable }`, `ActionCtx = { app, window: ?*Window, tab: ?*Tab (focused target), arg: ?[]const u8 (digit/param), source: enum { keyboard, palette, menu, rpc, ghostty, automation } }`. A catalog entry without a handler is hidden from the palette and its keys are inert. `wmux.action.run {action, arg?}` invokes any action (automation, tests, CLI `wmux action run`).

### 8.2 KeyRouter pipeline (`input/router.zig`, W1-5)

Inputs: `app/message_loop.zig: preTranslate` for `WM_KEYDOWN`/`WM_SYSKEYDOWN` on wmux HWNDs (before `TranslateMessage`), and every WebView2 `AcceleratorKeyPressed` (browser panes and web panels). Steps:
1. Ignore `VK_PROCESSKEY`, `VK_PACKET` and IME composition. Plain or Shift-only keys that produce printable text (letters, digits, punctuation, space) never match; bare-key viewer shortcuts are implemented inside pages. Enter, Esc, Tab, arrows and F-keys may match when a binding exists for the current context.
2. Build the stroke (`input/altgr.zig`): if the event's modifier state includes Ctrl+Alt (AltGr = synthetic LCtrl + RAlt, or physical LCtrl+LAlt) **and** `ToUnicodeEx(vk, scan, state, buf, 0x4 /* no keyboard-state change */, hkl)` yields printable text on the active layout, the stroke is **text** and never matches ("text always wins"; the table is rebuilt on `WM_INPUTLANGCHANGE`).
3. Lazily compute the context snapshot (8.5).
4. Look up bindings for the stroke (8.6 precedence), evaluate `when`; context-specific beats global; `priority_routing` wins its context.
5. A chord prefix enters a pending state (1.5 s, `key_sequence` hint in the tab bar, Esc cancels).
6. Run the handler. Consume the key if it returned `handled` or the action is not `performable`; otherwise pass it through (fixes B4: Ctrl+Tab and friends consumed when nothing happens).
7. Unclaimed keys continue to the focused HWND: terminal → Ghostty bindings → PTY; WebView2 → page.

### 8.3 Stroke grammar and matching (`wmux_proto/strokes.zig`)

- Modifiers `ctrl|control|ctl`, `shift`, `alt|opt|option`, `win|super`; `cmd` is rejected in `wmux.json` with a hint and translated in `cmux.json` (8.6). Keys: letters, digits, cmux key names, `enter return tab space escape backspace delete insert home end pgup pgdn up down left right f1…f24 mouse4 mouse5`, punctuation `` , . / ; ' [ ] \ - = ` ``.
- Chords: a two-element JSON array (`["ctrl+b","c"]`) or `"ctrl+b c"`. Unbind values: `null`, `""`, `none`, `clear`, `unbound`, `disabled`.
- Matching: **letters by virtual key** (layout-aware mnemonics); **digits and punctuation by scan-code position** (US layout positions), so AZERTY digits and ISO bracket keys work deterministically; hints display the active layout's key label (`MapVirtualKeyEx`). Numbered actions match 1–9.

### 8.4 Terminal-safety rules and tiers (Windows deviation from cmux's Cmd defaults)

Defaults that can fire while a terminal has focus MUST NOT use:
1. `Ctrl+<printable key>` without Shift (C0 controls, readline, vim). Exceptions kept for Windows Terminal parity: `Ctrl+C` (copy only with a selection, performable), `Ctrl+V` (paste only outside the alternate screen, so vim keeps visual block), `Ctrl+,` (WT settings), Ghostty font size `Ctrl+= / Ctrl++ / Ctrl+- / Ctrl+0`.
2. `Alt+<key>` without other modifiers (Meta; PSReadLine and readline bind `Alt+0..9` to digit-argument), except `Alt+F4`.
3. `Ctrl+Alt+<key that produces text on the active layout>` (AltGr).
4. Bare keys or `Shift+<key>` (except Ghostty's `Shift+Insert` paste and `Shift+PgUp/PgDn/Home/End` scroll); bare F1–F10 (htop, mc); `Win+<key>` (OS); `Ctrl+Shift+Left/Right` (PSReadLine word selection); `Ctrl+PgUp/PgDn`; `Ctrl+Enter`.

Allowed tiers: **A** `Ctrl+Shift+<key>` (cmux `⌘<key>`; the legacy encoding duplicates `Ctrl+<key>`, so nothing typeable is lost; Windows Terminal's convention); **B** `Ctrl+Shift+Alt+<key>` (cmux `⌘⇧<key>`, and `⌃⌘`/`⌥⌘` variants when A is taken; subject to the AltGr rule); **C** `Alt+Shift+<key>` (cmux `⌥⌘<key>`; Windows Terminal's pane tier; readline folds `M-<UPPER>` to `M-<lower>`); **N** navigation: `Ctrl+Tab`/`Ctrl+Shift+Tab`, `Ctrl+Alt+<arrows|PgUp|PgDn>` (never text on any layout), `F11`, `Alt+F4`. Plain `Ctrl`/`Alt`/bare keys are allowed only in non-terminal contexts (browser, web panels, palette, sidebar focus, right-sidebar focus, find field, TextBox). A unit test pins the table: no default violates these rules and no two defaults share a stroke in overlapping contexts.

On layouts where a tier-B chord produces text (e.g. Polish Programmer `Ctrl+Alt+Shift+N` = Ń), the text wins and that default is unavailable; `config doctor --keys` and the Settings shortcuts page list the defaults shadowed on the active layout.

### 8.5 Contexts and when-clauses (`input/context.zig`, `wmux_proto/when.zig`)

Grammar (pure Pratt parser, cmux semantics): `! && || ( ) == != =~ < <= > >= in [..] true false`; unknown keys are false. Context keys: `terminalFocus browserFocus webPanelFocus markdownFocus markdownEditFocus diffViewerFocus filePreviewTextEditorFocus fileExplorerFocus textBoxFocus todoFocus sidebarFocus rightSidebarFocus commandPaletteVisible findVisible terminalFindVisible terminalAlternateScreen workspaceCanvasLayout panelKind sidebarMode paneCount workspaceCount`, computed from the focused HWND class plus window and panel state. `shortcuts.when.<id>` overrides an action's built-in clause.

### 8.6 Customization and precedence

1. `wmux.json` `shortcuts.bindings.<id>`: literal Windows strokes.
2. `cmux.json` `shortcuts.bindings.<id>`: macOS strokes translated by `input/mac_translate.zig`: `cmd`→`ctrl+shift`; `cmd+shift`, `cmd+opt` (non-letter), `cmd+ctrl`→`ctrl+shift+alt`; `cmd+opt+<letter>`→`alt+shift+<letter>`; `opt`→`alt`; `ctrl`→`ctrl`. A translation that collides with another binding or violates 8.4 for a terminal-context action is dropped with a `config doctor` warning (`<id>: cmux.json stroke 'cmd+x' translates to 'ctrl+shift+alt+x' which collides with <id2>; set it in wmux.json`).
3. A trigger explicitly bound in the user's Ghostty config (any non-default `keybind =` line, found by diffing against `Keybinds.init` defaults) suppresses the router's **default** on that trigger, so existing custom wmux keybinds keep working (Windows deviation; `config doctor` lists each shadowed default). It never beats a JSON binding.
4. Router defaults from the catalog.
5. Ghostty default keybinds (terminal focus only), then the PTY.

Live reload goes through the settings watcher; the Settings recorder writes `wmux.json`.

### 8.7 Ghostty plumbing (core edits pre-wired in W0-A3; keybind pruning and tab semantics in W1-5)

- `src/input/Binding.zig`: one new action `wmux: []const u8` (`keybind = ctrl+b>c=wmux:newSurface`, `keybind = ctrl+shift+alt+3=wmux:selectSurfaceByNumber:3`); scope `.surface`.
- `src/apprt/action.zig` + `include/ghostty.h`: one apprt action `wmux_action` appended at the end of `Key`; `src/Surface.zig performBindingAction` forwards it; `app/perform_action.zig` calls `input.actions.invoke`; GTK/embedded runtimes list it as unimplemented; `src/input/command.zig` lists it under "no command". These edits land in W0-A3 so no Wave 1 WP touches those files.
- Ghostty tab actions follow cmux semantics by default (`wmux.ghosttyTabActions = "workspace"`): `new_tab`→new workspace, `goto_tab:N`→workspace N (1-based; fixes the off-by-one), `next_tab`/`previous_tab`/`last_tab`/`move_tab`/`close_tab`→workspace navigation, reorder and close; `"surface"` restores today's per-pane meaning. Split actions → wmux splits; `toggle_quick_terminal`, `toggle_visibility`, `toggle_maximize` keep their meaning. `performAction` returns the real performed bool (fixes `performable:`).
- The win32 block of `Keybinds.init` (`Config.zig` ~6782–6825 + shared tail) is pruned of every trigger the router now owns or that steals terminal keys (`ctrl+t`, `ctrl+w`, `ctrl+b`, `ctrl+alt+b`, `ctrl+enter`, `ctrl+shift+{e,o,h,!,i,j,n,q,t,w,p,f,enter,pgup,pgdn,left,right}`, `ctrl+,`, `ctrl+shift+,`, `ctrl+tab`, `ctrl+shift+tab`, `ctrl+pgup/pgdn`, `alt+1..9`, `ctrl+alt+arrows`, `ctrl+super+[ ]`, `super+ctrl+shift+arrows`, `ctrl+shift+alt+j`, `ctrl+shift+super+j`, `ctrl+v`); `shift+insert` is repaired to `paste_from_clipboard` (B3); `ctrl+shift+k`→`clear_screen` is added. Kept: `ctrl+c` (performable copy), `ctrl+shift+c/v`, `ctrl+insert`, `ctrl+shift+a`, font size keys, `shift+pgup/pgdn/home/end`, `ctrl+shift+up/down` (jump to prompt), `escape` (end search, performable).

### 8.8 Command palette integration

The palette (W2-7, native) lists catalog actions that have a handler, `palette = true` and a satisfied `when`, with live trigger hints from the router's effective bindings; plus providers (workspace/surface switcher, recently closed, layouts, settings toggles, custom `actions`/`commands`, schema error rows) and Ghostty `command-palette-entry`. It opens over web panes through the router.

### 8.9 Presets and migration

`wmux_proto/keymap_presets.zig`: `windows-terminal` (Alt+Shift+= / Alt+Shift+- splits, Alt+arrows focus, Ctrl+Alt+1..9 workspaces), `linux-ghostty` (Alt+1..9 surfaces, Ctrl+Shift+O/E splits), `tmux` (Ctrl+B chords), `wmux-classic` (pre-parity defaults: Ctrl+T, Ctrl+W, Ctrl+B, Alt+1..9, Ctrl+Enter). `cmux config preset <name>` writes only the differences into `shortcuts.bindings`. Release notes carry the old→new table; a one-time "keymap changed" notice links to the presets.

The full default table is **Appendix A**.

Risks: keyboard-layout matrix (AZERTY, QWERTZ, Polish Programmer, Japanese IME): pure tests over recorded `ToUnicodeEx` tables plus the existing IME harness; dead keys and win32-input-mode (the router never calls state-mutating `ToUnicode`); muscle memory (presets, release notes).

---

## ADR-9. Session persistence

### 9.1 Files (`STATE\session\`)

`session.json`; `session-previous.json` (copied from `session.json` at launch before the first save; backs "Restore Previous App Launch"); `session.json.bak` (ReplaceFileW backup); `scrollback\<surface-uuid>.vt`; markers `session.running` (`{pid, process_start_filetime}`) and `session.restoring`; quarantine names `session.unusable-<ms>.json`, `session.crashed-<ms>.json`, `session.schema-v<N>.json`.

### 9.2 Schema v3 (abridged; nested per window, `ext` per object)

```json
{ "schema": "wmux-session", "version": 3, "app_version": "1.2.0", "channel": "stable",
  "created_at": "2026-10-15T10:00:00.000Z", "clean_exit": true, "scrollback_captured_at": null,
  "handles": { "next": { "window": 3, "workspace": 18, "workspace_group": 2, "pane": 41, "surface": 77 } },
  "windows": [ { "id": "UUID", "ref": 1,
    "placement": { "x": 0, "y": 0, "w": 1600, "h": 1000, "maximized": false, "fullscreen": false,
                   "monitor": "\\\\.\\DISPLAY1", "dpi": 144 },
    "sidebar": { "visible": true, "width": 240, "scroll": 0 },
    "right_sidebar": { "visible": false, "width": 300, "mode": "files" },
    "selected_workspace": "UUID",
    "groups": [ { "id": "UUID", "ref": 1, "name": "api", "collapsed": false, "pinned": false, "anchor": "UUID" } ],
    "workspaces": [ { "id": "UUID", "ref": 7,
      "title": { "custom": "api", "auto": "pwsh", "source": "user" }, "description": "…",
      "cwd": "C:\\src\\api", "env": { "AWS_PROFILE": "dev" }, "group": "UUID", "pinned": false,
      "focused_pane": "UUID", "zoomed_pane": null,
      "layout": { "split": { "dir": "horizontal", "ratio": 0.5, "a": { "pane": "UUID" }, "b": { "pane": "UUID" } } },
      "panes": [ { "id": "UUID", "ref": 12, "selected_tab": "UUID", "ext": {},
        "tabs": [ { "id": "UUID", "ref": 30, "title": { "custom": null, "auto": "pwsh", "source": "process" }, "pinned": false,
          "panel": { "kind": "terminal", "cwd": "C:\\src\\api", "remote_cwd": null, "wsl_distro": null,
                     "spawn": { "argv": ["pwsh.exe", "-NoLogo"], "shell_kind": "pwsh" }, "font_size": 13.0,
                     "scrollback": "scrollback/UUID.vt" },
          "ext": { "agents": { "kind": "claude", "session_id": "…", "launch": {} } } } ] } ],
      "ext": { "status": {}, "workspace_style": { "color": "#3B82F6" }, "notifications": { "unread": [] } } } ],
    "ext": {} } ] }
```

Other `panel` kinds: `{"kind":"browser","url","back":[…],"forward":[…],"zoom","profile","devtools","muted"}`, `{"kind":"web","app","params","state"}`, `{"kind":"placeholder","reason":"hibernated"}`. Each `ext` object holds one key per feature, written by that feature's state `snapshot` and read by `restore` (ADR-1.3); unknown `ext` keys round-trip untouched, so older builds never drop newer data. Ratios are f32 and round-trip within 1% (the old f16 cast is dropped). Limits (cmux): 12 windows, 128 workspaces per window, 512 surfaces per workspace; scrollback 4,000 lines or 400,000 characters per terminal (tail kept).

### 9.3 Save mechanics (`features/session/`, W1-7)

- Model events set a dirty flag. An 8 s repeating timer serializes on the UI thread into an arena, fingerprints the JSON without volatile fields (Wyhash) and, if it changed, hands the bytes to a single coalescing writer thread: write `session.json.tmp`, `FlushFileBuffers`, `ReplaceFileW(session.json, tmp, session.json.bak)` (`MoveFileExW(WRITE_THROUGH)` for the first save).
- **Full save** (layout + scrollback) on `quit`, `close_all_windows`, the last window's `WM_CLOSE`, `WM_QUERYENDSESSION`/`WM_ENDSESSION` (broadcast-window hook; `ShutdownBlockReasonCreate("Saving wmux session")`; synchronous save with a 2 s scrollback budget) and before an update relaunch. Per-window `WM_CLOSE` overwrites are removed (fixes B8 and the last-closed-window-wins bug). `RegisterApplicationRestart("--restore", RESTART_NO_CRASH|RESTART_NO_HANG)` at startup.
- **Scrollback checkpoints** at most every 60 s, only for terminals with new output and after 5 s without typing, with a per-tick budget; the screen is copied under `renderer_state.mutex` and formatted on a worker.

### 9.4 Restore on launch

Skipped when `WMUX_DISABLE_SESSION_RESTORE`/`CMUX_DISABLE_SESSION_RESTORE` is set, in test mode unless `WMUX_TEST_SESSION_RESTORE=1`, on explicit launch intent (path, URL, `-e`, `--working-directory`, forwarded `new_window`), or when `session.restoring` exists from a crashed restore (the snapshot is renamed `session.crashed-<ms>.json` and a notice is shown; the next launch restores normally). Steps: write `session.restoring`; create windows hidden and fit placement with `SetWindowPlacement` clamped to the monitor work area (fixes the workarea/screen drift); build workspaces, groups, panes and tabs with `adopt()`ed handles; restore feature `ext` state; show windows; spawn terminals **staggered** (active workspace first, then one every 30 ms through a task queue); browser and web panels stay lightweight until shown; apply agent resume (ADR-10.7); delete `session.restoring`. Restore replaces state; it never appends into window 0.

### 9.5 Scrollback replay (terminal-side, shell-agnostic)

- Save: Ghostty's screen formatter emits VT with SGR only; OSC 0/1/2/7/9/52/99/133/777/1337 and color-changing OSC 4/10–19/104/110–119 are stripped; CRLF normalized; tail-capped.
- Replay: a new `termio.Options.restore_history: ?[]const u8` (W1-7; `src/termio/Termio.zig`/`Options.zig`) is fed through the stream handler **before** the PTY read thread starts, followed by `\r\n` × rows (so ConPTY's initial viewport clear erases only blank lines) and an SGR reset. Identical for cmd, pwsh, bash and WSL; never types into the shell; never touches shell history or the title. `CMUX_RESTORE_SCROLLBACK_FILE`/`WMUX_RESTORE_SCROLLBACK_FILE` is also exported for cmux-style shell integrations. The dead `saveAllScrollback`/`restoreScrollback` (which typed history into PTY input) is deleted. Prototyped in a W0-D spike before W1-7 starts.

### 9.6 Working directories

The `.pwd` apprt action (OSC 7 and OSC 9;9) updates `Tab.cwd` (`features/meta/api.onPwd`, wired by W1-7); the focused tab drives the workspace's current directory. Restore uses the tab cwd → workspace cwd → `%USERPROFILE%` (if the directory is gone). New splits and tabs inherit the focused tab's cwd (fixes "splits don't inherit"). WSL tabs save `remote_cwd` and restore with `wsl.exe --cd <dir> -d <distro>`. Shell-integration fixes (W1-3): PowerShell 5.1 uses `[char]27` instead of "`e"; cmd.exe gets `PROMPT=$e]9;9;$P$e\$e]133;A$e\$P$G$e]133;B$e\` when the user's PROMPT is the default; `bash.exe`/`zsh.exe` (Git Bash/MSYS) are detected for integration.

### 9.7 Browser and web panels

Browser tabs save URL, an app-side back/forward list (maintained from `HistoryChanged` + `SourceChanged`; WebView2 has no session-state blob, Appendix E), zoom, profile, devtools and mute state; restore navigates to the current URL and serves back/forward beyond native history by synthetic navigation. Web panels save `{app, params, state}`.

### 9.8 Reopen previous, crash recovery, import/export, migration

- `session.restore_previous` (`reopenPreviousSession`, `cmux restore-session`, which launches the app if needed) loads `session-previous.json` as additional windows; beeps when there is nothing to restore.
- Corrupt `session.json` → moved to `session.unusable-<ms>.json`; restore tries `.bak`, then `session-previous.json`. A newer schema is preserved as `session.schema-v<N>.json` and skipped.
- `session.running` present at launch with a dead PID (or a different process start time) = unclean exit: scrollback checkpoints are merged (never over a newer save), `session restore` agent recovery is offered (ADR-10.7) and the crash notice is shown.
- `session.export`/`session.import` (`restore-session --export|--from`) apply cmux's untrusted-import sanitizer (no automatic resume, no env, no SSH, URL scheme filtering).
- Migration: when no v3 file exists, `%LOCALAPPDATA%\ghostty\session-state.json` (v2 or v1) is converted once into window 0 (ids minted, `node_type/direction/ratio/left/right` mapped, per-tab cwd kept, browser tabs without URL become `about:blank` browser tabs) and renamed `.migrated`; the old `window-state` file seeds window 0's placement. v2 is never written again. Golden v2 files drive the unit tests.

Risks: ConPTY repaint vs injected history (W0-D spike; e2e with 100 numbered lines under cmd, pwsh and WSL); restore storms (staggered spawns, lazy panels); write amplification (fingerprint skip).

---

## ADR-10. Agent integrations

### 10.1 Hook entrypoint (`src/wmux_cli/hooks/`, W3-1)

`cmux hooks <agent> <event> [--workspace ID] [--surface ID] [--source NAME]`; compatibility aliases `claude-hook <event>`, `codex-hook <event>`, `feed-hook --source <name>` (hidden from help). The hook runs in the slim CLI (fast start, no PowerShell anywhere in the path; fixes the pwsh dependency and the `ghostty.exe` naming bug):

1. Read stdin JSON (≤ 1 MiB; prompt length measured before compaction for `prompt_length`).
2. Outside wmux (no `CMUX_SURFACE_ID`/`CMUX_WORKSPACE_ID` and no flags), or `CMUX_<AGENT>_HOOKS_DISABLED=1`/`WMUX_<AGENT>_HOOKS_DISABLED=1` → print the agent's neutral ack (`{}` or the agent-specific decision) and exit 0.
3. Map the native event name to cmux's subcommand set through the agent's `AgentDef` (session-start, prompt-submit, pre-tool-use, post-tool-use, stop, notification, session-end, subagent-stop, push-notification, auto-name, inbox-wait, inbox-drain, cron-create-guard, feed, …); sanitize the launch command (cmux rules: keep model, sandbox, config and cwd flags; drop prompts, credentials and session selectors).
4. Update the store (§10.2).
5. Send `wmux.agent.hook {agent, event, seq, session_id, surface_id, workspace_id, cwd, pid, transcript_path, tool_name, message, permission_mode, prompt_length}` (pipe lane; acknowledged after enqueue) with a 200 ms connect cap and a 2 s reply deadline. On failure, spool to `STATE\agents\spool\<session>\<seq>.json`; the app drains spools in seq order at startup and when the directory changes.
6. Permission/question/plan events become feed items via `feed.push` once W5's feed exists; until then they produce needs-input notifications.
7. Print the ack and exit 0 within 2 s. A hook never blocks or fails its agent.

Installed hook commands use the **absolute forward-slash path** of `cli/cmux.exe`, valid in Git Bash (Claude Code on Windows runs hooks through it), cmd and pwsh: `"C:/Users/me/AppData/Local/Programs/wmux/cli/cmux.exe" hooks codex stop`.

### 10.2 Session store

`STATE\agents\<agent>-hook-sessions.json`, field-compatible with cmux's records (agent session id, workspace id, surface id, cwd, pid when available, lifecycle `running|idle|needsInput|unknown`, sanitized launch command, transcript path, timestamps). **The CLI is the writer** (cmux: "session hooks write `~/.cmuxterm/<agent>-hook-sessions.json`"), under `LockFileEx` on `<file>.lock`, atomic replace, per-entry corruption tolerance; the app reads it and prunes under the same lock. `cmux sessions [list]` reads it offline with cmux's filters (`--agent --session --workspace --surface --cwd --limit --all --json`).

### 10.3 Surface binding

Explicit `--surface`/`--workspace` → `CMUX_SURFACE_ID`/`CMUX_WORKSPACE_ID` → app side: the hook process's pipe-client PID job membership (ADR-3.9; the Windows replacement for cmux's tty match) → the stored mapping for the same session id → none (ack and exit). No title heuristics. Surface ids are durable across restore (ADR-2).

### 10.4 Lifecycle state machine (`features/agents/logic/lifecycle.zig`, pure)

`AgentSession` per surface: `{surface_id, workspace_id, kind, session_id, transcript_path, state, pid, pid_start_time, version, last_activity_ms, pending_background}`. States: `unknown`, `running` (prompt-submit, pre/post-tool), `needsInput` (permission, question, plan, notification), `idle` (stop without background work), `backgroundWorkPending` (stop with background work), `ended` (session-end or exit watcher). Transitions follow cmux's table; duplicate events are no-ops; every change bumps a monotonic version. Backstops: an exit watcher (`OpenProcess(SYNCHRONIZE)` + `RegisterWaitForSingleObject` → task; identity checked by PID + creation time) and a transcript tail on a worker that clears stuck `running` states. Consumers read the `agents` api/events: sidebar agent rows and turn notifications (`agent_status`, W3-4), resume (`resume`, W3-5), feed (W5), auto-naming (W5), hibernation (W5), and `surface.input_state` (draft guard, W3-1). Events `agent.hook.<HookEventName>`.

### 10.5 Installers (`src/wmux_cli/installers/`, `src/wmux_cli/agents/`, W3-1 + W3-3)

Commands: `hooks setup [agent] [--agent n] [--yes]`, `hooks uninstall [agent]`, `hooks <agent> install|uninstall`, aliases `setup-hooks`, `uninstall-hooks`, `codex install|uninstall`, `claude-hook install` (user-settings hooks for WSL and non-wmux Claude), `hooks setup --wsl [distro]` (writes into `\\wsl.localhost\<distro>\home\<user>\…` with commands calling `/mnt/c/…/cli/cmux`).

```zig
// src/wmux_cli/agents/codex.zig
pub const def = AgentDef{
    .id = "codex", .aliases = &.{}, .binaries = &.{"codex"},           // SearchPathW + PATHEXT detection
    .config = .{ .env_dir = "CODEX_HOME", .default_dir = "%USERPROFILE%\\.codex", .files = &.{ "hooks.json", "config.toml" } },
    .format = .json_merge,                                              // json_merge | json_flat | toml_block | yaml_block | plugin_file | script_dir
    .events = &.{ .{ .native = "SessionStart", .sub = "session-start" }, .{ .native = "UserPromptSubmit", .sub = "prompt-submit" }, .{ .native = "Stop", .sub = "stop" } },
    .resume = .{ .argv = &.{ "codex", "resume", "{session}" } },
    .feed = false, .wrapper = true, .timeout_s = 5,
};
```

Windows paths follow cmux's agent table: Claude `%USERPROFILE%\.claude\settings.json` (`CLAUDE_CONFIG_DIR`), Codex `%CODEX_HOME%` (default `%USERPROFILE%\.codex`), Gemini `%USERPROFILE%\.gemini\settings.json`, OpenCode `%USERPROFILE%\.config\opencode\plugins\`, Cursor `%USERPROFILE%\.cursor\hooks.json`, Pi `%USERPROFILE%\.pi\agent\extensions\`, and the rest of cmux's 19 agents. JSON edits splice tokens through `json_edit.zig` (unrelated bytes unchanged); TOML/YAML use sentinel blocks; preview + confirmation on a TTY, `--yes` required otherwise; atomic writes; idempotent "already up to date"; cmux's exact output and summary lines. A bare `hooks setup` skips Claude unless `--agent claude` (the wrapper covers Claude; cmux semantics). Migration: `hooks setup`/`uninstall` remove the old `ghostty-capture.ps1` shims and entries (matching old and new command forms); `src/cli/hooks.zig` and `src/shell-integration/agent-hooks/` are deleted. W3-1 creates the `AgentDef` type and the claude/codex entries; W3-3 fills the other 17 (Grok, OpenCode, Pi, OMP, Campfire, Amp, Cursor CLI, Gemini, Kiro CLI, Rovo Dev, Copilot, CodeBuddy, Factory, Qoder, Kimi Code, Muse Code, Antigravity); the 19 stub files pre-seeded by W0-A3 avoid conflicts.

### 10.6 Wrappers (`src/wmux_cli/wrappers/`, W3-2)

`STATE\shims\<build-id>\agents\claude.exe` (argv[0] = `claude`):
1. **Pass through unchanged** (run the real binary with identical argv) when: not inside wmux (no `CMUX_SURFACE_ID`); `CMUX_CLAUDE_HOOKS_DISABLED=1`; `automation.claudeCodeIntegration=false` (read from `STATE\agents\agent-integrations.json`, which the app writes on settings change; the wrapper never parses settings); the control pipe does not answer `system.ping` within 300 ms; a non-session subcommand (`mcp`, `config`, `--help`, `--version`, …; list cached hourly from `claude --help`); or a managed policy forbids it.
2. Locate the real binary: `automation.claudeBinaryPath`, else `SearchPathW` over PATH minus the shims dir with PATHEXT (`.exe` preferred; `.cmd` launched as `cmd.exe /d /s /c "<quoted>"` with BatBadBut-safe quoting from `wmux_proto/win_argv.zig`; `.ps1` via `pwsh -NoProfile -File`).
3. Inject `--session-id <uuid>` for new sessions and `--settings <file>`, where `STATE\agents\claude-settings\<surface>.json` holds the generated hook settings merged with any user-supplied `--settings` (Windows deviation: a file instead of inline JSON avoids command-line quoting).
4. Export `CMUX_CLAUDE_PID` and the `CMUX_AGENT_LAUNCH_*` capture variables.
5. `CreateProcessW` with inherited handles inside a `KILL_ON_JOB_CLOSE` job; the wrapper ignores Ctrl+C (`SetConsoleCtrlHandler(NULL, TRUE)`) so the console event reaches the child; it waits and exits with the child's code (Windows emulation of `exec`).

`codex.exe` follows the same pattern with per-invocation `-c hooks.<event>=…` injection exactly as cmux's "Codex wrapper precedence", never modifying `~/.codex`; `surface.sync_codex_native_title` lives here. Other wrapper agents follow their catalog entries. The app (env_identity, W1-3) creates the shims directory; W3-2 registers which wrapper names it contains.

### 10.7 Resume (feature `resume`, W3-5)

- `surface.resume.set/get/clear` follow cmux: a proposal is stored without auto-resume trust and the reply carries `approval_required: true`; approvals are prefix-based, HMAC'd with a DPAPI secret, stored in `STATE\trust\resume-approvals.json`, and granted from the terminal context menu or Settings > Terminal > Resume Commands.
- On relaunch with `terminal.autoResumeAgentSessions` (default true; `automation.agentAutoResume` honored), each restored terminal with an agent binding gets `initial_input` = the sanitized resume command quoted for its `shell_kind` by `wmux_proto/shell_quote.zig` (pwsh `& 'claude' '--resume' '<id>'`; cmd `^`-escaping; POSIX for bash/WSL) + `\r`, typed after the first prompt (OSC 133;A) or a 1.5 s fallback; the shell survives the agent.
- Guards: Claude sessions without a transcript are skipped; a duplicate-launch census (process command lines containing the session id, live PIDs from the store) prevents double resume and shows a notice suggesting `cmux restore --surface`; `agents.launchers` prefixes are honored.
- `session restore [--list] [--session id]…` (`session.agent_recovery.list/restore`) after an unclean exit; `restore`/`fork` run `CreateProcessW` in the calling console inside a kill-on-close job and propagate the exit code.
- Legacy `+session capture` → `surface-resume set`; `agent_session.zig`'s `Store` becomes the in-app cache of the persisted store.

### 10.8 tmux compatibility and team launchers (W3-6)

- `src/wmux_cli/tmux/`: a pure parser and format engine (`#{pane_id}`, `#{session_name}`, …) implementing cmux's verb/flag/format-token/target table; `-V` prints `tmux 3.4`; `%N` pane ids are surface ref numbers; `-t` accepts tmux forms or wmux handles; unsupported commands print `Unsupported tmux compatibility command: <x>`. Buffers and hooks live in `STATE\agents\tmux-compat-store.json` under `LockFileEx`. Commands execute as v2 calls. `cmux __tmux-compat <argv>` shares the code.
- `tmux.exe` (argv[0]) routes to wmux only when a launcher marker is set (`CMUX_CLAUDE_TEAMS_CMUX_BIN`, `CMUX_OMO_CMUX_BIN`, …); otherwise it runs the next real `tmux` on PATH (MSYS2/Cygwin) or prints `tmux: not found` and exits 127.
- **Teammate commands** (Windows deviation): tmux runs `sh -c <cmd>`; the shim creates the split with `initial_command = {argv: [<bash.exe>, "-lc", <cmd>]}`, where bash comes from `CLAUDE_CODE_GIT_BASH_PATH` → `SHELL` (MSYS path converted) → `where bash`; for WSL-hosted agents `["wsl.exe","-d",<distro>,"--cd",<dir>,"--","bash","-lc",<cmd>]`. Commands travel as structured argv or a verbatim cmdline, never whitespace-split (fixes the quoting bug in today's IPC `command`).
- Launchers `claude-teams`, `codex-teams`, `omo`, `omx`, `omc`: prepend `STATE\shims\<build-id>\teams`, set `TMUX=<STATE>\tmux\<workspace-uuid>,<token>,<N>`, `TMUX_PANE=%<N>`, `TERM=screen-256color`, unset `TERM_PROGRAM`, set `CMUX_SOCKET_PATH`, clear `CMUX_SOCKET`, canonicalize `CMUX_*` to the launching surface, set the marker; `claude-teams` adds `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`; main-vertical placement (agent column); spawn and wait.
- `wait-for [-S] <name>`: file-based in `STATE\wait-for\`, atomic rename to consume.

Risks: Claude Code's agent-team tmux backend on native Windows is unverified (W0-D spike; WSL fallback documented; the dispatcher still ships for omo/omx/codex-teams); agent config formats drift (one `AgentDef` per agent + golden files); npm `.cmd` shims mangle quoting (`win_argv` + `cmd /d /s /c`).

---

## ADR-11. Sidebar rendering and the right sidebar

### 11.1 Decision

- The left sidebar becomes its own child HWND `WmuxSidebar` drawn with **Direct2D 1.1 + DirectWrite** (`ID2D1HwndRenderTarget`; `D2DERR_RECREATE_TARGET` handled). Rows come from a pure row-model → layout → paint pipeline with feature-contributed content and virtualized scrolling.
- The right sidebar is a child HWND **mode host**.
- Tab bars stay GDI (moved to `ui/tabbar/` in W0, with one shared geometry) until W5 converts them to D2D through `ID2D1DCRenderTarget::BindDC` inside the window's existing double-buffered paint.

Rationale: cmux rows are variable-height and rich (pills with icons and colors, progress, spinners, links, multi-line branch/directory, port chips, notification previews, checklists, group headers). GDI cannot draw color emoji and is poor at anti-aliasing and alpha. A separate HWND isolates invalidation, scrolling, keyboard focus and the future UIA provider, and avoids painting under GL/WebView2 children. `dwrite` is already linked (`SharedDeps.zig`); W0-A3 adds `d2d1`. A WebView2 left sidebar was rejected (startup-critical, always visible, cross-HWND drag/focus complexity, memory).

### 11.2 Pipeline (`ui/sidebar/`, W1-8)

1. `logic/row_model.zig` (pure): `build(input: RowModelInput) []Row`. Row kinds: `group_header`, `workspace`. A workspace row has title-line slots (leading unread badge or spinner, pin, mute, color rail, status glyph, title, trailing badge or close) and ordered lines from contributors.
2. `logic/row_layout.zig` (pure): measures through a `TextMeasurer` interface (DirectWrite implementation; a fake with fixed advances in tests) at the current DPI and width; produces `RowGeom{top, height, element rects}`; cached by content hash per window; invalidated by model version, width or DPI change. One geometry source for paint, hit-testing, drag targets and tooltips (replaces the uniform `sidebarItemHeight` stride).
3. `paint.zig`: paints visible rows only.
4. `hit.zig`: point → (row id, element, action).

### 11.3 Row contributors (`ui/sidebar/contrib.zig`)

```zig
pub const RowContributor = struct {
    id: []const u8,
    slot: Slot,                                   // pre-assigned order
    build: *const fn (b: *RowBuilder, ws: *const Workspace, ctx: *const RowContext) void,
};
// RowBuilder primitives: line(icon, runs, color, link), pills(items), progress(value, label), chips(ports),
//                        markdown(block, max_lines), collapsible(max_visible, more_label), spinner(), badge(count)
pub const Slot = enum(u8) { description = 10, agent_status = 20, status_entries = 30, notification_preview = 40,
    progress = 50, log = 60, branch_dir = 70, pull_requests = 80, ports = 90, remote = 100, todo_summary = 110,
    custom_metadata = 120, loading = 130 };
```

Owners: `description` (W4-5 `workspace_style`), `agent_status` (W3-4 `agent_status`), `status_entries`/`progress`/`log`/`loading` (W2-6 `status`), `notification_preview` + the unread badge (W2-5 `notifications`), `branch_dir`/`pull_requests`/`ports` (W2-6 `meta`), `remote` (W6), `todo_summary` and `custom_metadata` (W5). Contributors read feature state only and never paint. Visibility follows cmux's sidebar settings (`sidebar.hideAllDetails`, `showBranchDirectory`, `showPullRequests`, `showPorts`, `showLog`, `showProgress`, `showNotificationMessage`, `compactAgentStatus`, …); a hidden detail also stops its data probe.

### 11.4 Behaviors

- Scrolling: `WM_MOUSEWHEEL` with smooth deltas, an overlay thumb shown while scrolling, `ensureRowVisible` on select/create, auto-scroll while dragging.
- Selection happens on mouse-up when no drag started; drags never select; drag reorder shows an insertion line; Esc cancels; Ctrl/Shift-click multi-select (for `groupSelectedWorkspaces`). Today's drag reorder keeps working (W1-8).
- Keyboard focus mode (`focusSidebar`): Up/Down move, Enter selects and focuses the pane, Esc returns focus, F2 renames, Ctrl+Up/Down reorders; a focus ring is drawn.
- Tooltips: one `TOOLTIPS_CLASSW` per window, `TTF_TRACK`, only for truncated text.
- Animation: a spinner timer (~15 fps) runs only while a visible row is loading and the window is neither minimized nor cloaked (`DwmGetWindowAttribute(DWMWA_CLOAKED)`); honors `SPI_GETCLIENTAREAANIMATION`.
- Icons: Segoe Fluent Icons (Windows 11) with Segoe MDL2 Assets fallback through `ui/icons.zig` (mapping from cmux SF Symbol names); color emoji with `D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT`; text in Segoe UI Variable at `sidebar.fontSize` × DPI.
- Theme tokens derive from the Ghostty background/foreground plus the accent; WCAG 4.5:1 contrast floor; high contrast switches to system colors; cmux `sidebarAppearance` tint/opacity; Mica/Acrylic glass presets in W5.
- Removed: the "+ New workspace" row (footer button and `Ctrl+Shift+N` remain) and the static "1..9" prefix (shortcut hint pills appear on modifier hold, `shortcuts.showModifierHoldHints`).
- Test hook: `wmux.debug.sidebar.snapshot` returns the row model and geometry as JSON (assert data, not pixels).

### 11.5 DPI and accessibility

- W1-8 handles `WM_DPICHANGED` on the top-level window (via a `chrome` window hook): apply the suggested rect, rebuild fonts and text formats, `SetDpi` on render targets, rescale tab bars and overlays, forward to terminal surfaces (`Surface.handleDpiChange`, dead today) and WebView2 bounds; handle `WM_GETDPISCALEDSIZE`. Fixes ui-model 8.1#5.
- UIA (W7): a provider for the sidebar HWND (`List`/`ListItem`, Name = title + status summary; Selection, SelectionItem, Invoke patterns). `WM_GETOBJECT` returns `UiaReturnRawElementProvider` only for this HWND; providers answer on the UI thread and never take renderer locks (avoiding the oleacc deadlock the current code works around).

### 11.6 Right sidebar host (`ui/right_sidebar/host.zig`, frame by W1-8)

A D2D mode bar above a content child. Modes come from features' `right_sidebar_modes`: `RightSidebarMode{ id, title, icon, order, create: fn (*Window) anyerror!Content }` where `Content` is a `WebHost` (files, find, sessions/vault, feed, `custom:<name>`), the native Dock (a second `SplitTree(Pane)` owned by the workspace or window, laid out with `model/layout.zig`), or the legacy status strip (mode `wmux.status`, migrated from `RightSidebar.zig` by W1-8). Mode, width and visibility are per window and persisted; the host invalidates on relevant model events (fixes the stale repaint). RPC `wmux.right_sidebar.{get,set,toggle,show,hide,focus}`; CLI `right-sidebar …`. `wmux.rightSidebar.visible=false` sets only the initial visibility; the toggle always works (fixes the verified bug). Positional `Ctrl+1..5` under `rightSidebarFocus`.

Risks: D2D device loss over RDP (recreate; tested over RDP); a D2D child next to GL and WebView2 siblings (`WS_CLIPSIBLINGS`; W0-D spike); text measurement cost with many rows (hash cache + virtualization).

---

## ADR-12. Testing strategy

### 12.1 Unit tests

- Pure logic lives in `logic/` directories (ADR-1.2). Test names are `"unit: <feature-or-layer>: <behavior>"` so the existing CI filter `-Dtest-filter="unit: "` picks them up.
- Each feature's `logic/tests.zig` imports its logic files; `fast_tests.zig` imports every `logic/tests.zig`; each `mod.zig` has `test { _ = @import("logic/tests.zig"); }` so the full suite includes them too. A logic file never referenced from a `tests.zig` fails `scripts/check-manifest.ps1`.
- Required pure modules with tests: `wmux_proto/*` (uuid, handles, selectors, envelope, errors, idformat, jsonc, json_edit, when, strokes, shell_quote, win_argv, settings resolve/validate), `input/logic/*` (mac_translate, AltGr tables from recorded `ToUnicodeEx` data, keymap conflict test), `model/logic/*` (layout, ops arithmetic, registry round trip), `rpc/logic/*` (framer, admission, rate limiter, request state machine, legacy adapter mappings, text-v1 parsers, event frame encoding), `ui/sidebar/logic/*` (row model, row layout at scales 1.0/1.25/1.5/2.0), feature logic (notification store, agent lifecycle, session schema/migration, meta parsers), `wmux_cli` (args, targets, output, tmux engine, AgentDef golden files).
- Fake model: `model/logic/fake.zig` builds window/workspace/pane/tab graphs without HWNDs (model structs keep HWND/content pointers optional). Live-pipe tests use names `wmux-test-<pid>-<n>`.

### 12.2 Build steps

- `zig build test-fast`: std + `wmux_proto` + all `logic/` files; no Ghostty dependencies; target ≤ 60 s.
- `zig build test-cli`: tests rooted at `src/wmux_cli/main.zig`.
- `zig build test -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Dtest-filter="unit: "` plus the existing filters (`sidebar`, `wsl`, `win-pwd`, `ipc:`).
- Full `zig build test` (~6.5 min) nightly and before wave tags; known environment-specific failures (e.g. `cli.ssh-cache.DiskCache` on the gnu test binary, GTK comptime pulls) are listed in `test/known-failures.txt`; any unlisted failure fails.

### 12.3 Test mode in the app (`app/runtime_env.zig` + owners)

- `WMUX_TEST_MODE=1`: enables `wmux.debug.*` methods; fake in-process clipboard (never touches the user's clipboard); MessageBox auto-answer + `wmux.debug.dialogs.list`; no sounds or beeps; no update check; no registry writes (AUMID, protocol, CLSID); no global hotkeys; no tray icon; toasts go to the sink; animations instant; session restore off unless `WMUX_TEST_SESSION_RESTORE=1`; shims pruning confined to STATE; WebView2 user data under STATE.
- `WMUX_TEST_HIDDEN=1` (amended 2026-10-15 per spike S2, `docs/arch/spikes/S2-hidden-instances.md`): every top-level window (no `WS_CHILD`, parent != `HWND_MESSAGE`) is created through one path with `WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE`, without `WS_VISIBLE`, sized with `AdjustWindowRectEx` for the FINAL ex-style to a 1600×1000 client clamped to the primary monitor's work area and positioned at the work-area origin; immediately after `CreateWindowExW` and before the first `ShowWindow` it is cloaked with `DwmSetWindowAttribute(DWMWA_CLOAK=13, TRUE)` and the cloak verified with `DWMWA_CLOAKED=14`; only if cloaking fails it is moved to (-32000, -32000) (GL screenshots are then blank: report captures as inconclusive). Shown only with `SW_SHOWNOACTIVATE`; top-level `SetWindowPos` gets `SWP_NOACTIVATE`; `app/foreground.zig` activation calls are no-ops; a thread-local `WH_CBT` hook returns 1 for `HCBT_ACTIVATE` and moves unowned top-level creations (MessageBox, menus, tooltips) off-screen; window-placement save/restore is skipped; not in the taskbar or Alt-Tab. The alternate-desktop fallback is rejected. Reference patch: `docs/arch/spikes/proto/S2/wmux-hidden-mode.patch`.
- Isolation: `WMUX_CHANNEL=test-<8hex>`, `WMUX_STATE_DIR`, `WMUX_CONFIG_DIR`, Ghostty `--config-default-files=false --config-file=<root>\ghostty.conf`; `WMUX_SOCKET_MODE=automation` (the external harness is allowed); `WMUX_TEST_TOAST_SINK=<file>`.
- Logical focus (`wmux.debug.focus_state`, `system.identify`) is the asserted truth, never `GetFocus`.

### 12.4 End-to-end harness

PowerShell 7 module `test/e2e/WmuxTest.psm1` (no external modules; no Pester), runner `test/e2e/run.ps1`, coverage `test/e2e/coverage.ps1`. Full specification in **Appendix D**.

### 12.5 Per-WP acceptance and merge gates

- Every WP ships: unit tests for its pure core; at least one suite `test/e2e/suites/<area>/<wp-id>.e2e.ps1` whose header lists `# covers: <feature-id>` for every covered id (or `# manual: <feature-id> <reason>` waivers); CLI goldens when it adds commands; docs; a changelog fragment (§15.9).
- Local gate `scripts/gate.ps1 -Wp <id>`: `zig fmt --check` on changed files, debug build, `test-fast`, `test-cli`, `unit: <area>` filtered tests, the WP's e2e suites + the smoke suite, ownership and manifest checks (~6–8 min warm).
- Merge gate `scripts/gate.ps1 -Full` (integrator, on the rebased branch): debug and ReleaseFast builds, `test-fast`, `test-cli`, `unit: ` + existing filters, all e2e suites in parallel (budget 10 min), contract tests (CLI no-socket probes, keymap conflicts, settings schema golden, error strings), ownership. A red master blocks the queue; the offending merge is reverted, not patched in place.
- All worktrees share `ZIG_GLOBAL_CACHE_DIR`; `scripts/new-worktree.ps1` bootstraps a worktree (stages `WebView2Loader.dll`, runs the first build).

### 12.6 CI

GitHub Actions `windows-latest` (interactive session; WebView2 runtime preinstalled). Jobs: (a) build + `test-fast` + `test-cli` + unit filters; (b) ReleaseFast build + e2e with Mesa llvmpipe: a pinned `mesa-dist-win` release (checksum verified) whose `opengl32.dll` and `libgallium_wgl.dll` are copied next to `wmux.exe` in the test staging directory only (Ghostty needs GL ≥ 4.3; llvmpipe provides 4.5), `GALLIUM_DRIVER=llvmpipe`; (c) CLI probes and offline commands with no app; (d) nightly full `zig build test` + full e2e; optional WSL lane. Artifacts on failure: screenshots, the instance's `events.jsonl`, logs, toast sink, dialogs log.

### 12.7 Flakes and coverage

A test may retry once; a test that flakes twice within 7 days moves to `suites/_quarantine/` (stabilization WP) and is fixed within the wave. Never sleep; wait on conditions or events. `coverage.ps1` reads `# covers:` tags and reports parity coverage per area against `matrix.csv`; each wave tag records the report.

---

## ADR-13. Remote and SSH (plan for Wave 6)

### Decision

Windows OpenSSH has no ControlMaster. One `ssh.exe` **carrier per resolved route**, owned by the app and ref-counted across workspaces on that route, multiplexes PTY, proxy, file-transfer and relay streams to a clean-room Zig daemon `wmuxd-remote` (cmux's Go daemon is GPL and is not reused). Phase A (W6a) delivers plain `cmux ssh` workspaces (terminals run `ssh.exe` directly), reconnect and `ssh -D` browser egress; Phase B (W6b) delivers the daemon carrier, persistent PTYs, relay and the PID-admitted proxy.

### Design outline

- **Protocol** (`wmux_proto/remote/`): newline JSON-RPC control plus length-prefixed binary frames for PTY/proxy data after `hello`. Methods modeled on cmux's documented `cmuxd-remote`: `hello` (version + capabilities, enforced), `ping`, `proxy.open|close|write|stream.subscribe`, `session.open|close|attach|resize|detach|status` (smallest screen wins), `pty.attach|write|resize|detach|close|list`, `fs.put|get` (uploads over the carrier, no scp), `relay.accept`.
- **Daemon** (`src/remote/daemon/`): static `wmuxd-remote` cross-compiled by the `remote-daemon` build step for linux x86_64/aarch64 and darwin x86_64/aarch64, with an embedded SHA-256 manifest.
- **Bootstrap** (`features/remote/bootstrap.zig`): `ssh -G <dest>` (killed after 2 s) resolves the route; one `ssh.exe -T <route>` probe runs `uname -s; uname -m` and checks `~/.wmux/bin/wmuxd-remote/<ver>/<os>-<arch>/wmuxd-remote`; a missing or stale daemon is streamed over the same connection (`umask 077; mkdir -p; cat > tmp; sha256sum tmp; mv`; never promote a 0-byte file); remote `~/.wmux/bin/wmux` and `cmux` wrappers are installed as argv[0] relays (`wmuxd-remote cli`); errors are stage-specific (create dir, transfer, verify, install).
- **Carrier** (`features/remote/carrier.zig`): `ssh.exe -T [merged opts] <dest> ~/.wmux/bin/…/wmuxd-remote serve --stdio --persistent --slot <slot>` with overlapped stdio pipes and a reader thread.
- **Terminals**: a remote surface is a local ConPTY running `cli\cmux.exe ssh-pty-attach --workspace <id> --session <sid>`; the helper sets raw VT console mode and pumps bytes through the app's pipe to the carrier, reusing all terminal machinery. Detach on close never kills the remote shell; persistent PTY sessions survive reconnect and relaunch (`pty.session.persistent_daemon`); `ssh-session-list|attach|cleanup`. A direct termio backend is a later optimization.
- **Reconnect** (`features/remote/RemoteWorkspace.zig`): `connecting | ready | reconnecting | parked | disconnected`; backoff 3, 6, 12 … 60 s; keepalive (`ServerAliveInterval`); suspended while the host is unreachable (TCP probe); re-armed on `WM_POWERBROADCAST(PBT_APMRESUMEAUTOMATIC)` (broadcast-window hook) and `NotifyIpInterfaceChange`; escalation from proxy failure to re-bootstrap; restored workspaces stay `connecting` during retryable failures; sidebar remote row (badge, target, state, Reconnect button) in slot `remote`.
- **CLI relay**: the daemon listens on remote `127.0.0.1:<port>`, writes `~/.wmux/socket_addr` and `~/.wmux/relay/<port>.auth`, and tunnels to `features/remote/relay.zig`; mutual HMAC-SHA256 challenge; deny-by-default allowlist = methods with `relay = true` plus closed param schemas bound to the owning workspace and generation; denied → `remote_relay_denied`; limits 16 connections, 10 s handshake, 30 s lifetime. Remote shells get `CMUX_SOCKET_PATH=127.0.0.1:<port>` (the CLI accepts `host:port` only for the relay). Remote notifications and agent hooks arrive tagged `origin = ssh_relay:<ws>`. A security review is mandatory before merge.
- **Browser egress**: one WebView2 environment per route (user data `STATE\webview2\remote-<routehash>`, `AdditionalBrowserArguments = "--proxy-server=socks5://127.0.0.1:<p> --proxy-bypass-list=<-loopback>"`, so remote `localhost` works); a local SOCKS5/CONNECT broker (`features/remote/proxy.zig`) tunnels each stream over `proxy.open` and admits a connection only if its owning PID (`GetExtendedTcpTable(TCP_TABLE_OWNER_PID_CONNECTIONS)`) belongs to that environment's `BrowserProcessId` process tree (Chromium's SOCKS5 has no authentication). Phase A uses `ssh -D` without admission (documented caveat). Local workspaces are never proxied; a bind conflict shows a `proxy_unavailable` notice.
- **ssh-tmux mirror** (`features/remote_tmux/`): a hidden `ssh.exe -tt <dest> tmux -CC [attach -t <s>]` feeds Ghostty's existing control-mode parser (`src/terminal/tmux/{control,layout,output,viewer}.zig`). Mapping (Windows deviation; wmux has no splits inside a tab): tmux **session → workspace group**, **window → workspace** (titled `session:window`), **pane → pane** with one tab whose layout comes from tmux's cell rects. Mirrored panes use a new termio backend kind `external` (output from `%output`; input as `send-keys -H` hex chunks); that core change to `src/termio/backend.zig` is owned by the `remote_tmux` WP. Sizing via `refresh-client -C` claims (debounced 180 ms); divider drags end in `resize-pane`; mutations are sent as control commands and layout events redraw. Methods `remote.tmux.*`; CLI `ssh-tmux`.
- **Mosh / EternalTerminal**: `cmux mosh` returns `not_supported` with guidance (no maintained native Windows client) unless `wmux.remote.moshCommand` names a user-provided client (e.g. WSL mosh). local-tmux/local-zellij via WSL are deferred to W7.
- **Session**: workspace `ext.remote` stores route, slot, relay port and PTY session ids; reattach on restore.

Risks: OpenSSH variants (`ssh -G` support, agent pipe `\\.\pipe\openssh-ssh-agent`) → detect and fall back; daemon scope is XL → Phase A first; daemon tests run in a Linux CI job (WSL or container); relay allowlist security review.

---

## ADR-14. Phasing

### 14.1 Principles

1. Foundations that change shared structures land **first and sequentially** in one core lane (Wave 0). W0-A3 also **pre-wires every cross-cutting hook point** that Wave 1 needs (core Ghostty hooks, termio option plumbing, the `wmux:` binding action, facades in `App.zig`/`ui/Window.zig`, link libraries, build steps) with stub implementations that delegate to feature/layer files, so Wave 1 WPs fill owned files and touch only the hot files listed in §14.4.
2. After Wave 0, a WP adds files under its features, CLI families and web apps, and touches frozen/hot files only per its wave's hot-file table.
3. Each WP is ≤ L (2–4 agent-days); XL work is split or done as consecutive merges by the same agent.
4. **Wave kickoff**: the integrator lands one interface commit per wave (stub `api.zig` functions named in WP specs, new catalog lines, CLI family stubs, folded CCRs); WPs branch from it.
5. One merge at a time; merge order follows dependencies; every merge is rebased and gated (ADR-12.5).
6. Every wave ends with a one-agent stabilization WP (flakes, doc consolidation, coverage report, release build, dogfood checklist). A wave tag is set only when the full gate is green on master.
7. Spikes de-risk the platform unknowns before the waves that depend on them.

### 14.2 Milestones

| Milestone | Exit criteria |
|---|---|
| **M0** (end W0) | Identical behavior on the new skeleton (plus the listed W0 bug fixes); all manifests, stubs, registries, ext structs, hooks and build steps exist; harness smoke suite green on the legacy protocol; spike decision notes S1–S7 merged. |
| **M1** (end W1) | v2 server with cmux envelope, errors, admission, deadlines and access modes; `cli\cmux.exe`/`wmux.com` with grammar, discovery, `ping`/`capabilities`/`rpc`, offline help/version/socket-status; `CMUX_*`/`WMUX_*` env + jobs; `cmux.json`/`wmux.json` layering, live reload and `config` CLI; KeyRouter + Windows keymap + `wmux:` action; web panel framework (About panel); session v3 autosave/restore/migration/scrollback replay; D2D sidebar + per-monitor DPI. Dogfoodable. |
| **M2** (end W2) | Agents drive wmux exactly like cmux: windows/workspaces/panes/surfaces v2 + CLI, terminal I/O, events stream, notifications core, sidebar status/metadata, palette/find/focus history, browser automation core. All legacy JSON commands flipped to v2 implementations. |
| **M3** (end W3) | Hooks, wrappers, 19-agent installers, agent status rows, turn notifications, resume, tmux teams, WinRT toasts with click-to-jump, notifications popover and pane. Legacy `wmux-ipc-<pid>` pipe removed. |
| **M4** (end W4) | Markdown viewer, file preview/editor and `open` router, diff viewer + comments, Settings window + shortcuts editor, groups/pins/colors/context menus, drag and drop, recently closed/layouts/custom actions/project trust, right-sidebar Files and Find. |
| **M5** (end W5) | Extended local features: todo and status lanes, feed, vault, custom sidebars, dock, task manager/`top`/`memory`, browser II, automations, agent messages, auto-naming, hibernation, copy mode, TextBox, image paste, keep awake, window hints, global search, updater, read plane, text-v1 verbs, D2D tab bars. |
| **M6** (end W6) | Remote: ssh workspaces, reconnect, persistent PTYs, CLI relay, browser egress, ssh-tmux mirroring. |
| **M7** (end W7) | Polish: localization, UIA accessibility, canvas, sleepy mode, policy ADMX, `install-cli` and distribution, diagnostics, local-tmux via WSL. |

### 14.3 Wave 0 (max 4 agents; only W0-A touches `src/`)

| WP | Scope | Owns | Size |
|---|---|---|---|
| **W0-A** core lane: A1 → A2 → A3, each merged and gated | ADR-1.8 (extraction, model, skeleton, pre-wiring) | `src/apprt/win32/**`, `src/wmux_proto/**`, `src/wmux_cli/**`, `build.zig`, `src/build/**`, core Ghostty files for pre-wiring | XL (3 merges) |
| **W0-B** harness v0 | `test/e2e/WmuxTest.psm1`, `run.ps1`, `coverage.ps1` skeleton, smoke suite over the legacy JSON protocol (launch hidden once A1 lands; `workspace-list`, `tab-new`, `send`, `read-screen`); replace the stale `test/win32` class/binary names | `test/e2e/**`, `test/win32/**` | M |
| **W0-C** tooling | `scripts/{new-worktree,gate,check-ownership,check-manifest}.ps1`, `docs/arch/` (this document, WP and CCR templates), CI workflow updates, `AGENTS.md` drift fixes (pipe and binary names, pointer to `docs/arch`), `test/known-failures.txt` | `scripts/**`, `.github/**`, `docs/arch/**`, `AGENTS.md`, `test/known-failures.txt` | M |
| **W0-D** spikes S1–S7 (§14.7) | prototypes in throwaway branches; decision notes merged as docs only | `docs/arch/spikes/**` | M |

W0-A3 pre-wiring list (in addition to ADR-1.8 A3): `Binding.Action.wmux` + `apprt.Action.wmux_action` + `ghostty.h` + `Surface.performBindingAction` forward + `app/perform_action.zig` arm (`input.actions.invoke`), GTK/embedded "unimplemented" entries, `command.zig` "no command"; core `src/Surface.zig` obtains `rt_surface.spawnHooks()` (`protected_env`, `job`) and `rt_surface.restoreHistory()` when declared and passes them into `termio.Exec.Config` (`protected_env` applied after `env_override`) and `termio.Options` (`restore_history`, ignored until W1-7); `src/Command.zig` gains a `job: ?HANDLE` field (used by W1-3); apprt `Surface.zig` gets `spawnHooks()` → `features.env_identity.api.spawnHooks` and `restoreHistory()` → `features.session.api.restoreHistory` (stubs); `App.init` calls `settings.init`, `rpc.server.start` (legacy server behind the facade until W1-1) and `features.lifecycle.init`; `ui/Window.zig` calls `ui.sidebar.attach(window)` and `ui.right_sidebar.attach(window)` facades and dispatches `window_hooks`; `model/TabContent.zig` already has the `.web` and `.placeholder` variants with stub types; `src/build/SharedDeps.zig` links `d2d1 windowscodecs crypt32 bcrypt comctl32 propsys iphlpapi winmm shlwapi oleaut32 uiautomationcore` for win32 (amended 2026-10-15 per spike S1: do NOT link `runtimeobject` or `combase`, which are not linkable with Zig 0.15.2's x64 mingw; WinRT entry points come from `extern "api-ms-win-core-winrt-l1-1-0"` / `"api-ms-win-core-winrt-string-l1-1-0"` declarations and COM from `ole32`).

### 14.4 Wave 1: platform foundations (8 WPs; W1-1 is two consecutive merges by one agent)

| WP | Scope | Owns (adds) | Hot files (sole owner in W1) | Depends | Size |
|---|---|---|---|---|---|
| **W1-1** RPC server | ADR-3.1–3.8: naming, marker, launch pipe + single instance, admission, rate limits, lanes, deadlines, modal hold, deferred replies, v2 envelope/errors, registry dispatch, `Ctx` + router, legacy JSON adapter over the registry, text-v1 framework (`ping`, `auth`, `help`), access modes + auth (job ∨ ancestry ∨ capability, password, env/policy overrides, readOnly), `system.ping`, `system.capabilities`, `auth.login`, `wmux.debug.*` framework (`ready`, `app.quit`, `dialogs.list`, `clipboard.get/set`, `focus_state`, `layout`) | `rpc/**` (non-frozen), `app/single_instance.zig`, features `system`, `debug` | `rpc/types.zig` (bodies) | W0 | XL = **W1-1a** (transport, naming, single instance, admission, deadlines, lanes, envelope, errors, dispatch, legacy adapter; merges first) + **W1-1b** (access modes, auth, capability, password, overrides, text-v1; merges after W1-3) |
| **W1-2** CLI | ADR-4 except agent wrappers/hooks/tmux: grammar, discovery, client, output/`--id-format`, help topics, offline framework (help, version, guide, docs, welcome, socket-status), `ping`/`capabilities`/`rpc`, legacy `+verb` mapping, `wmux.exe` relay + argv routing, deletion of the `src/cli` wmux verbs, `cli\` layout + sh launchers, the `wmux` namespace command framework, installer `[Files]`, no-socket probes | `src/wmux_cli/**`, `wmux_proto/{idformat,win_argv}.zig` | `src/main_ghostty.zig`, `src/cli/**`, `dist/windows/installer.iss` | W0 (W1-1a for e2e) | L |
| **W1-3** Env, jobs, shell integration | ADR-3.9: protected env, `CMUX_*`/`WMUX_*`, PATH prepend, WSLENV, TERM default, auth-env removal, instance + per-tab jobs, job queries (`inInstanceJob`, `surfaceForPid`, `processIds`), shims directory creation/pruning, shell-integration fixes (PowerShell 5.1, cmd PROMPT with OSC 9;9/133, `bash.exe`/`zsh.exe` detection) | `platform/job.zig`, `features/env_identity/**`, `src/shell-integration/**` | `src/Command.zig`, `src/termio/Exec.zig`, `src/termio/shell_integration.zig` | W0 | M |
| **W1-4** Settings | ADR-5 except the Settings window: settings resolve/validate/schema dump/known keys, JSONC + lossless editor, `settings/` layer (loader, snapshot, watcher, Ghostty overlay/overrides/legacy keys via replay steps, policy), `ui/notice.zig`, `config` CLI family, `settings-schema` output | `wmux_proto/settings/**` (not other features' spec files), `wmux_proto/{jsonc,json_edit}.zig`, `settings/**`, `ui/notice.zig`, `wmux_cli/commands/config.zig` | none | W0 | L |
| **W1-5** Keys | ADR-8: KeyRouter, contexts, when-clauses, strokes, AltGr, chords, mac translation, presets data, the router entry API for WebView2 accelerators, handlers for existing behaviors, `wmux.action.run`, `shortcuts` feature, Ghostty tab-action semantics, keymap conflict test | `input/**` (not `actions.zig`), `actions.zig` of the 13 pre-seeded features only, `features/shortcuts/**`, `wmux_proto/{strokes,when,keymap_presets}.zig` | `src/config/Config.zig` (`Keybinds.init` win32 block only), `app/message_loop.zig` | W0, W1-4 (merge after) | L |
| **W1-6** Web panels | ADR-6: `platform/webview2.zig` completion, `web/**` (environment/profiles, `WebHost`, `WebPanel`, bridge, assets, theme, file hosts), `BrowserPane` onto `WebHost` basics + router accelerator call, `about` panel, `src/web/_shared` + `_vendor/README.md` | `web/**`, `src/web/_shared/**`, `src/web/about/**`, `features/about/**` | `platform/webview2.zig` | W0 | L |
| **W1-7** Session v3 | ADR-9: schema, writer, autosave, full-save hooks (broadcast window), restore on launch, crash markers, v2 migration, scrollback save + replay, `.pwd`→`Tab.cwd`, placement, `session.restore_previous`, `restore-session` CLI | `features/session/**`, `features/meta/api.zig` (`onPwd` only), `ui/placement*.zig`, `wmux_cli/commands/session.zig` | `src/termio/Termio.zig`, `src/termio/Options.zig` | W0 (spike S3) | L |
| **W1-8** Sidebar D2D + DPI | ADR-11: D2D/DWrite bindings, `ui/gfx/**`, `ui/sidebar/**` (child HWND, row pipeline, contributors API, scrolling, keyboard focus, tooltips, drag reorder), right-sidebar host frame + legacy strip mode, `ui/dpi.zig` + `WM_DPICHANGED` window hook, `chrome` feature, `wmux.right_sidebar.*` + CLI `right-sidebar`, `wmux.debug.sidebar.snapshot` | `ui/gfx/**`, `ui/sidebar/**`, `ui/right_sidebar/**`, `ui/dpi.zig`, `features/chrome/**` (not `actions.zig`), `wmux_cli/commands/right_sidebar.zig` | `platform/d2d.zig`, `platform/dwrite.zig`, `ui/Window.zig` (only if a pre-wired facade proves insufficient) | W0 (spike S7) | L |

Merge order: W1-1a → W1-3 → W1-1b → W1-2 → W1-4 → W1-5 → W1-6 → W1-7 → W1-8. Other W1 WPs rebase onto W1-1a before running v2-based e2e.

### 14.5 Wave 2: core cmux parity (8 WPs)

| WP | Scope | Owns | Hot files (sole owner in W2) |
|---|---|---|---|
| **W2-1** Windows & workspaces | `window.*` (list, current, create, focus, close, display, displays), core `workspace.*` (list, current, create with cwd/title/description/env/initial_input/focus, select, next, previous, last, rename, close, reorder, reorder_many, move, move_to_window, action, env, equalize_splits), multi-window + `--window`, workspace env, lifecycle events, legacy flips (`workspace-*`) | features `windows`, `workspaces`; CLI families `window`, `workspace` | `model/ops/window.zig`, `model/ops/workspace.zig` |
| **W2-2** Panes, surfaces, tree | `pane.*`, structural `surface.*` (list, current, create, split, split_off, close, focus, move, reorder, drag_to_split, action, catalog), `tab.action`, `system.identify`/`system.tree` with caller resolution (job), container-explicit selection, legacy flips (`tab-*`, `surface-*`, `new-split`, `swap-split`, `break-pane`, `move-pane`, `select-layout`, `sync-input`) | features `panes_surfaces`, `system` (identify/tree), `layouts` (legacy select-layout only), `sync_input`; CLI families `pane_surface`, `system` | `model/ops/pane.zig`, `model/ops/surface.zig`, `model/ops/move.zig` |
| **W2-3** Terminal I/O | `surface.send_text` (pending input queue, `input_queue_full`), `send_key` (named key table), `read_text`, `read_selection`, `refresh`, `health`, `respawn`, `clear_history`, `terminal.paste`, `debug.terminals`, `initial_input` vs `initial_command` argv (no whitespace splitting), legacy flips (`send`, `read-screen`, `capture-pane`) | feature `terminal_io`; CLI family `terminal_io` | none |
| **W2-4** Events | `events.stream`, `cmux events`, `events.jsonl`, socket-sourced event table, emission audit e2e over all lifecycle ops | feature `events`; CLI family `events`; `rpc/stream.zig` | `rpc/dispatch.zig` (event table) |
| **W2-5** Notifications core | ADR-7 except toasts/popover: store, unread, auto-read, OSC core change, ingress, pipeline, badges/ring/flash/taskbar overlay, legacy balloon kept, `app.focus_override.set`, `app.simulate_active`, `wmux.attention.set`, sidebar badge + preview contributors, legacy flips (`notify`, `flash-pane`) | feature `notifications`; CLI family `notify` | `src/Surface.zig`, `src/apprt/surface.zig`, `src/termio/stream_handler.zig`, `src/terminal/osc/parsers/kitty_notification.zig` |
| **W2-6** Sidebar status & metadata | `wmux.sidebar.*` + text verbs (`set_status`, `clear_status`, `list_status`, `set_progress`, `clear_progress`, `log`, `clear_log`, `list_log`, `sidebar_state`, `report_*`), `surface.report_*`, OSC 9;4 → sidebar + taskbar progress, git branch/dirty (watch `.git\HEAD` + bounded probe with in-flight guard), PR via `gh`, ports via jobs (IPv4 + IPv6), workspace loading, `pr` command, legacy flips (`set-status`, `set-progress`, `log`) | features `status`, `meta`; CLI family `sidebar_meta` | `platform/taskbar.zig` |
| **W2-7** Palette, find, focus history | native D2D palette (`ui/palette/**`: fuzzy ranking, usage stats, providers, Go to Workspace switcher), terminal find bar (`ui/find/**`: match counts from `search_total/selected`, prev/next, per-pane anchoring), focus history (back/forward/last), `surface.trigger_flash` | features `palette`, `find`, `focus_history` | apprt `Surface.zig` (removes the old palette/search popups) |
| **W2-8** Browser automation I | core `browser.*` (open_split, navigate, back, forward, reload, url.get, get.*, is.*, find.*, snapshot with `@eN` refs, eval, click, dblclick, hover, focus, type, fill, press, keydown, keyup, check, uncheck, select, scroll, scroll_into_view, wait, screenshot, console.*, errors.list, tab.*, dialog.*, frame.*, focus_webview, is_webview_focused, devtools.toggle), `NewWindowRequested` → tabs, `--surface` targeting, omnibar scheme fixes, legacy flips (`open`, `navigate`, `eval`, `snapshot`, `click`, `fill`) | feature `browser`; CLI family `browser`; `web/cdp/**` | `web/BrowserPane.zig` |

### 14.6 Waves 3–7

| Wave | WPs (feature owners) |
|---|---|
| **W3** agents & desktop delivery | W3-1 agents platform (`agents`: hook entrypoint, store, spool, lifecycle, exit watcher, `wmux.agent.hook`, `surface.input_state` + draft guard; CLI `hooks/`, `agents/{claude,codex}.zig`, family `hooks_agents`) · W3-2 wrappers (`src/wmux_cli/wrappers/**`) · W3-3 installers (`installers/**`, the other 17 `agents/*.zig`, delete `src/cli/hooks.zig` + old shims) · W3-4 `agent_status` (sidebar agent rows, spinner, compact mode, turn/permission/idle notifications, raw-OSC suppression, `jump-to-last-prompt`, `workspace.prompt_submit`) · W3-5 `resume` (auto-resume, `surface.resume.*`, `session restore`, `restore`/`fork`, approvals) · W3-6 `tmux_compat` (shim engine, team launchers, `wait-for`) · W3-7 `toasts` + `deeplinks` + `tray` (WinRT, AUMID, protocol, COM Reply, withdraw, sounds, `notifications.command`; hot: `dist/windows/installer.iss` `[Icons]`) · W3-8 `notifications` UI (popover/pane web panel, notification hooks policy, mute/reorder, persistence) |
| **W4** panels, settings, organization | W4-1 `markdown` · W4-2 `file_preview` (+ open router, `cmux open`, `file.open`, preview `read_selection`) · W4-3 `diff` + `comments` · W4-4 `settings_ui` · W4-5 `groups` + `workspace_style` + `context_menus` (`workspace.group.*`, pins, colors, descriptions, registry-driven context menus) · W4-6 `dnd` (OLE `IDropTarget`/`DoDragDrop` for tabs across panes/windows/sidebar, tear-off, file drops, drop zones) · W4-7 `history` + `layouts` + `custom_actions` (recently closed, `layout.*`, cmux.json actions/commands, project trust store) · W4-8 `files_explorer` + `find_in_dir` (right-sidebar modes) |
| **W5a** extended I | `todo` + `workspace_status` · `feed` · `vault` · `custom_sidebars` (JS runtime first, then the JSON dialect) · `dock` · `task_manager` (`system.top`, `system.memory`, per-surface process/memory/port accounting via jobs) · `browser_profiles` + browser II (cookies, storage, state, downloads, network, offline, viewport, geolocation, trace, screencast, profiles, import, history, omnibar suggestions, page find) · `automation` |
| **W5b** extended II | `agent_messages` · `auto_naming` · `hibernation` · `copy_mode` · `textbox` + `image_paste` · `keep_awake` + `hints` + `global_search` (+ `current.list`, `find-window`) · `updater` (correct repo URL) + capture (`window.screenshot`, `window.record.*` in `windows`) · core-lane performance WP (read plane, remaining text-v1 verbs, D2D tab bars with overflow) |
| **W6** remote | W6-1 Phase A (`cmux ssh` workspaces, flags, reconnect, `ssh -D` egress, sidebar row) · W6-2 protocol + daemon + build step · W6-3 bootstrap + carrier + persistent PTYs + `ssh-session-*` · W6-4 relay + remote notifications/agents · W6-5 browser egress broker + per-route environments · W6-6 `remote_tmux` mirror (+ termio `external` backend) · W6-7 remote file drop/explorer + `cmux ssh` deep links |
| **W7** polish | `i18n` · `a11y` (UIA for sidebar, tab bars, terminal `ITextProvider`) · `canvas` · `sleepy_mode` · `policy` (ADMX) · `install_cli` + distribution (signing, winget manifest) · diagnostics (crash reports, hang watchdog, profiling) · local-tmux/local-zellij via WSL · `agent_chat`/`welcome`/`about` polish |

### 14.7 Spikes (W0-D; decision notes in `docs/arch/spikes/`)

| Spike | Question | Consumers | Fallback |
|---|---|---|---|
| S1 Toasts | Unpackaged WinRT toast with registry-registered AUMID (no shortcut) shows and persists in Action Center; protocol activation click reaches the launch pipe with foreground rights; COM activator Reply works; `get_Setting` detection; `History.Remove` | W3-7 | Start-menu shortcut AUMID; balloon fallback |
| S2 Hidden instances | Off-screen `WS_EX_NOACTIVATE|WS_EX_TOOLWINDOW` + `SW_SHOWNOACTIVATE`: ConPTY spawn, GL rendering, WebView2 creation, `PrintWindow(PW_RENDERFULLCONTENT)`, zero focus change | W0-B, all e2e | alternate desktop via `CreateDesktop` (verify GL there) |
| S3 Scrollback replay | Pre-read-loop injection + `\r\n`×rows vs ConPTY's initial clear in cmd, pwsh, WSL | W1-7 | cmux-style env file + shell-side `cat` (pwsh/bash; no cmd replay) |
| S4 Agent shims | `claude.exe` in a prepended PATH dir wins over npm `claude.cmd`/`claude.ps1` in cmd, pwsh (command precedence across PATH dirs), Git Bash and Claude Code's own spawns; Ctrl+C through the wrapper; Claude Code agent-team tmux backend on native Windows with our `tmux.exe` | W3-2, W3-6 | shell functions/aliases from shell integration; WSL for teams |
| S5 WebView2 proxies | Two environments with different `--proxy-server` in one process; SOCKS5 + PID admission (`GetExtendedTcpTable` owner ∈ `BrowserProcessId` tree); loopback bypass | W6-5 | HTTP CONNECT + `BasicAuthenticationRequested` credentials |
| S6 CLI forwarders | Forwarders in `%LOCALAPPDATA%\Microsoft\WindowsApps` execute and persist in cmd/pwsh/Git Bash; AV behavior | W7 `install_cli` | documented manual PATH step |
| S7 D2D sidebar child | D2D child HWND next to GL and WebView2 siblings: z-order, flicker, resize, RDP device loss | W1-8 | D2D through `BindDC` in the window's paint (no child HWND) |

### 14.8 Critical path and risk ordering

Critical path: W0-A1 → W0-A2 → W0-A3 → W1-1a → W1-3/W1-2 → W2-1/W2-2/W2-3 → **M2** ("background agents act on their own pane over a cmux-compatible CLI", the highest-value parity fix). Highest technical risks in spike order: toast activation (S1, balloon fallback ships in W2-5), scrollback injection (S3), D2D child over GL/WebView2 (S7), KeyRouter vs IME/dead keys/win32-input-mode (W1-5 manual IME checklist), Claude teams on native Windows (S4), per-environment proxies (S5).

### 14.9 Merge protocol

- Wave kickoff interface commit (§14.1.4) → WPs branch from it in worktrees `wp/<id>-<slug>`.
- Before the gate: rebase onto master, regenerate nothing (no codegen), run `scripts/gate.ps1 -Wp <id>`.
- The integrator runs `scripts/gate.ps1 -Full` on the rebased head and merges `--no-ff`, one at a time. Two merges may be batched only when their ownership is disjoint and both gates passed on the same base.
- Hot-file conflicts are resolved by the owning WP only. A red master blocks the queue; the offending merge is reverted, not patched in place.
- Wave N+1 branches only after wave N's stabilization WP is merged and tagged.

---

## 15. Conventions for implementation agents

### 15.1 Before you start

1. Read §0, the ADRs for your area, this section, your WP spec (`owns`, `touches`, `appends`, `covers`, `depends`) and the `inventory/`, `gaps/`, `verify/` entries of every covered feature id. The inventory entry is the behavioral spec; the gap entry tells you where wmux is today; the verify entry corrects both.
2. Create your worktree with `scripts/new-worktree.ps1 -Wp <id>` (branch `wp/<id>-<slug>`, shared Zig cache, staged `WebView2Loader.dll`, first build).
3. Need a file outside your spec? Write a CCR (`docs/arch/ccr/<wp>-<n>.md`) and continue behind a stub. Never edit it "just a little".

### 15.2 Where to register things

| You add | Put it in | Picked up by |
|---|---|---|
| v2 method | `features/<id>/rpc.zig` (`pub const methods = [_]rpc.Method{…}`), declared in `mod.zig` as `rpc_methods` | `rpc/registry.zig` |
| legacy JSON command adapter | `features/<id>/legacy.zig` (`commands`) | `rpc/registry.zig` |
| cmux text-v1 verb | `features/<id>/text_verbs.zig` (`verbs`) | `rpc/registry.zig` |
| CLI command | `src/wmux_cli/commands/<family>.zig` (your family) + `help/<command>.txt` + golden `test/cli/golden/<command>.txt` | `commands/manifest.zig` |
| keybindable action | handler in `features/<id>/actions.zig`; the catalog entry already exists (new `wmux.*` actions: one sorted line in `wmux_proto/actions_catalog.zig`) | `input/actions.zig` |
| default shortcut | the catalog entry's `keys` (must pass the keymap conflict test and ADR-8.4) | KeyRouter |
| setting | `src/wmux_proto/settings/specs/<id>.zig`; run `zig build settings-schema` and commit `docs/wmux/schema/wmux.schema.json` | `specs_manifest.zig` |
| menu item | `features/<id>/contrib.zig: menu_items` (with a `MenuSite`) | `ui/contrib.zig` |
| palette entries | `features/<id>/contrib.zig: palette` | `ui/contrib.zig` |
| sidebar row content | `features/<id>/sidebar.zig: rows` using your pre-assigned `Slot` | `ui/contrib.zig` |
| right-sidebar mode | `features/<id>/contrib.zig: modes` | `ui/contrib.zig` |
| web panel kind | `features/<id>/panels.zig: kinds` + assets in `src/web/<app>/` | `ui/contrib.zig` |
| per-object state | `features/<id>/state.zig` (`App`, `Window`, `Workspace`, `Pane`, `Tab`) | `features/ext.zig` (pre-seeded) |
| session data | `snapshot`/`restore` on your state types | session writer |
| reactions to startup, shutdown, events, settings | `init`, `deinit`, `onEvent`, `onSettingsChanged` in `mod.zig` | `features/lifecycle.zig` |
| window or broadcast messages | `window_hooks` / `app_hooks` in `mod.zig` | `app/hooks.zig` |
| apprt action reaction (`.pwd`, `.progress_report`, …) | the `features/<id>/api.zig` function already called by `app/perform_action.zig` | pre-wired |
| event | one sorted line in `wmux_proto/events_catalog.zig` if new; `model.events.emit` from your store (lifecycle events only from `model/ops`) | bus, stream, log |
| background work / timer | worker thread + `app.tasks.post`; `app.timers.start` | — |
| Win32 extern | your marked section of `platform/win32.zig`, or a local `extern` in your feature | — |

### 15.3 File ownership

- Edit only files your WP spec lists (`owns`, `touches`, `appends`). `scripts/check-ownership.ps1` fails the gate otherwise.
- Never move, rename or reformat files you do not own; run `zig fmt` on changed files only.
- One owner per hot file per wave (§14 tables). Shared-appendable files: one entry per line, sorted, nothing else changed.
- Cross-feature calls only through `features/<other>/api.zig` or events; never import another feature's internals.

### 15.4 Coding rules

- Ground rules G1–G10 (§0.3) apply to every line.
- Logging: `const log = std.log.scoped(.<feature_id>);`. No `std.debug.print` in committed code.
- Errors: Zig errors internally; map to RPC codes only at the RPC boundary (`ctx.fail`), with cmux's exact strings where cmux defines them. No panics on user input.
- Memory: per-request arena for RPC handlers; long-lived state on the general allocator, freed in `deinit`; ownership of cross-thread payloads is explicit (sender frees if posting fails).
- Re-resolve objects by UUID after any modal loop, thread hop or async completion; never keep raw pointers in records that outlive them (notifications, menus, tasks).
- COM/WinRT: check every HRESULT; AddRef borrowed interfaces that outlive a callback; release before `CoUninitialize`.
- User-visible native strings go through `ui/strings.zig: tr("feature.key", "English default")` (no-op lookup until W7); web panels keep strings in `src/web/<app>/strings.js`.
- Never block the UI thread; never call activation APIs outside `app/foreground.zig`; never touch the clipboard outside `app/clipboard.zig`.

### 15.5 Tests

- Unit: put pure logic in `logic/`, name tests `"unit: <feature>: <behavior>"`, list the file in your `logic/tests.zig`, use `model/logic/fake.zig` for model graphs.
- E2E: `test/e2e/suites/<area>/<wp-id>.e2e.ps1`, header `# wp: <id>` and `# covers: <ids>`; start your own isolated instance (`Start-WmuxInstance`), drive only public surfaces (v2 RPC, CLI, events, `wmux.debug.*`), never sleep (use `Wait-WmuxCondition`/`Wait-WmuxEvent`), always stop the instance in `finally`.
- CLI: goldens for text output; `--help` works offline; error strings match cmux.
- The harness fails any test during which a test-instance window became foreground (Appendix D).

### 15.6 Build and test commands

```powershell
$Z = "C:\Users\Rey.ColonValero\zig-x86_64-windows-0.15.2\zig.exe"
$T = @('-Dapp-runtime=win32', '-Dtarget=x86_64-windows-gnu')
& $Z build @T                                   # debug (console subsystem), ~2.2 min incremental
& $Z build @T -Doptimize=ReleaseFast            # release (GUI subsystem)
& $Z build test-fast @T                         # pure logic + wmux_proto, ≤ 60 s
& $Z build test-cli @T                          # CLI tests
& $Z build test @T "-Dtest-filter=unit: <feature>"
& $Z build test @T "-Dtest-filter=unit: "       # all unit tests (CI filter)
& $Z build settings-schema @T                   # regenerate docs/wmux/schema/wmux.schema.json
& $Z fmt <changed files>
pwsh test/e2e/run.ps1 -Suite <area> [-Filter <text>] [-Parallel 4] [-Build Debug|Release]
pwsh scripts/gate.ps1 -Wp <id>                  # local gate (§12.5)
```

### 15.7 Commits and branches

- Branch `wp/<id>-<slug>`. Commit subject `<type>(<scope>): <summary> [<WP-id>]`, types `feat fix refactor test docs build chore perf`, scope = feature id or layer (`feat(notifications): add notification store [W2-5]`). Body: what and why, `Covers: <feature ids>`, CCRs referenced. Append the attribution trailer your harness requires.
- One logical change per commit; move-only commits separate from behavior commits; no generated build output; never force-push master.

### 15.8 Definition of done (per feature and per WP)

1. Behavior matches the inventory entries of every covered id (cmux names, params, results, errors, output text), or a deviation is recorded in Appendix E through the WP spec.
2. Registered only through extension points; ownership and manifest checks pass.
3. Pure-logic unit tests (`unit: <feature>: …`) cover the core; e2e suite tags every covered id (`# covers:`) or waives it (`# manual: <id> <reason>`).
4. CLI goldens and offline `--help` updated; settings specs added and schema regenerated.
5. Docs: `docs/wmux/features/<id>.md` (behavior, settings, CLI, Windows deviations) and `docs/wmux/cli/<family>.md` when CLI changed; changelog fragment `changes/<wp-id>.md`.
6. `scripts/gate.ps1 -Wp <id>` green locally and `-Full` green on the rebased head; no focus stealing; no new compiler warnings.

### 15.9 Docs and changelog

Never edit `CHANGELOG.md`, `README.md` or `docs/WINDOWS_FEATURES.md` directly: write `changes/<wp-id>.md` (user-visible changes, one bullet each) and your `docs/wmux/**` pages; the stabilization WP assembles release notes and consolidates top-level docs at each wave tag.

---

## Appendix A. Default Windows keymap (cmux shortcut → Windows binding → action id)

Tiers: **A** = Ctrl+Shift, **B** = Ctrl+Shift+Alt, **C** = Alt+Shift, **N** = navigation (ADR-8.4). "unbound" = available in the palette and rebindable. "n/a" = cloud, mobile, simulator or macOS-only; the id is accepted in config and inert. Context "global" means any focus; context-specific bindings beat global ones. Digits and punctuation match by scan-code position; letters by virtual key. This table is the source of `wmux_proto/actions_catalog.zig`; the keymap conflict test pins it.

### A.1 App and window

| Action id | cmux (macOS) | Windows default | Context | Notes |
|---|---|---|---|---|
| `openSettings` | ⌘, | Ctrl+, | global | WT convention (documented exception). Opens the Settings window (W4); before W4 opens `wmux.json` |
| `reloadConfiguration` | ⇧⌘, | Ctrl+Shift+, | global | A |
| `showHideAllWindows` | ⌃⌥⌘. | unbound | system-wide | binding it registers a global hotkey (`RegisterHotKey`) |
| `globalSearch` | ⌥⌘F | Alt+Shift+F | global | C |
| `newWindow` | ⇧⌘N | Ctrl+Shift+Alt+N | global | B (Ctrl+Shift+N = New Workspace, cmux ⌘N) |
| `closeWindow` | ⌃⌘W | Alt+F4 | global | system convention |
| `toggleFullScreen` | ⌃⌘F | F11 | global | N; frees Ctrl+Enter |
| `quit` | ⌘Q | Ctrl+Shift+Q | global | A; honors `app.confirmQuit`; full session save |
| `toggleSidebar` | ⌘B | Ctrl+Shift+B | global | A; frees Ctrl+B (tmux prefix) |
| `focusSidebar` | ⌃⌘E | Ctrl+Shift+E | global | A (VS Code "Explorer" mnemonic); `useSelectionForFind` is unbound instead |
| `showWindowHints` | ⌘J | Ctrl+Shift+J | global | A |
| `newTab` (New Workspace) | ⌘N | Ctrl+Shift+N | global | A |
| `newLocalWorkspace` | ⌃⌥⌘N | unbound | — | alias of `newTab` (all wmux workspaces are local) |
| `newBrowserWorkspace` | ⌥⌘N | Alt+Shift+N | global | C |
| `newCloudWorkspace`, `newCloudMachine`, `openTeamPicker` | ⌘Y, ⇧⌘Y, ⌥⇧⌘T | n/a | — | cloud |
| `saveLayoutTemplate` | ⌃⌘S | Ctrl+Shift+S | global | A ("Save as" mnemonic; editor Save is plain Ctrl+S in editor context) |
| `openFolder` | ⌘O | Ctrl+Shift+O | global | A (was split-right in old wmux defaults) |
| `reopenPreviousSession` | ⇧⌘O | Ctrl+Shift+Alt+O | global | B |
| `goToWorkspace` | ⌘P | Ctrl+Shift+Alt+P | global | B (swapped with the palette, Windows convention) |
| `commandPalette` | ⇧⌘P | Ctrl+Shift+P | global | A (WT / VS Code) |
| `commandPaletteNext` / `commandPalettePrevious` | ⌃N / ⌃P | Ctrl+N, Down / Ctrl+P, Up | `commandPaletteVisible` | non-terminal context |
| `agentInbox` | ⇧⌘I | Ctrl+Shift+Alt+I | global | B |
| `sendFeedback` | — | n/a | — | hosted |
| `showNotifications` | ⌘I | Ctrl+Shift+I | global | A (the inspector binding is removed) |
| `jumpToUnread` | ⇧⌘U | Ctrl+Shift+U | global | A (⌘U unused in cmux, so the A slot is free) |
| `jumpToLastPrompt` | ⇧⌘B | Ctrl+Shift+Alt+B | global | B |
| `toggleUnread` | ⌥⌘U | Alt+Shift+U | global | C |
| `markOldestUnreadAndJumpNext` | ⌃⌘U | Ctrl+Shift+Alt+U | global | B |
| `markAllNotificationsRead`, `clearAllNotifications` | — | unbound | — | opt-in (cmux) |
| `focusRightSidebar` | ⇧⌘E | Ctrl+Shift+Alt+E | global | B |
| `switchRightSidebarToFiles/Find/Sessions/Feed/Dock` | ⌃1…⌃5 (positional) | Ctrl+1…Ctrl+5 (positional by visible mode order) | `rightSidebarFocus` | `priority_routing`; non-terminal context |
| `switchRightSidebarToMachines` | ⌃6 | n/a | — | cloud |
| `triggerFlash` | ⇧⌘H | Ctrl+Shift+H | global | A |

### A.2 Navigation, workspaces, surfaces

| Action id | cmux (macOS) | Windows default | Context | Notes |
|---|---|---|---|---|
| `nextSurface` / `prevSurface` | ⇧⌘] / ⇧⌘[ | Ctrl+Tab / Ctrl+Shift+Tab | global | N; always consumed |
| `moveSurfaceLeft` / `moveSurfaceRight` | ⌥⇧⌘[ / ] | Ctrl+Shift+PgUp / Ctrl+Shift+PgDn | global | A on non-text keys |
| `moveSurfaceToPreviousPane` / `NextPane` | ⌃⇧⌘[ / ] | unbound | — | directional moves below cover it |
| `moveSurfaceToPaneLeft/Right/Up/Down` | ⌥⇧⌘←/→/↑/↓ | Ctrl+Shift+Alt+←/→/↑/↓ | global | B on non-text keys |
| `selectSurfaceByNumber` | ⌃1…9 | Ctrl+Shift+Alt+1…9 | global | B; numbered, 9 = last (Alt+digit is readline/PSReadLine digit-argument) |
| `nextSidebarTab` / `prevSidebarTab` | ⌃⌘] / ⌃⌘[ | Ctrl+Alt+PgDn / Ctrl+Alt+PgUp | global | N (next/previous workspace) |
| `nextSidebarTabInGroup` / `prevSidebarTabInGroup` | — | unbound | — | |
| `moveWorkspaceUp` / `moveWorkspaceDown` | ⌃⌥⌘[ / ] | Ctrl+Shift+Alt+PgUp / PgDn | global | B on non-text keys |
| `focusHistoryBack` / `focusHistoryForward` | ⌘[ / ⌘] | Ctrl+Shift+[ / Ctrl+Shift+], mouse X1 / X2 | `!browserFocus` | A (positional brackets) |
| `focusHistoryLast` | — | unbound | — | |
| `selectWorkspaceByNumber` | ⌘1…9 | Ctrl+Shift+1…9 | global | A; numbered, 9 = last (Ctrl+Shift+2/6 duplicate Ctrl+2/6, nothing lost) |
| `renameTab` | ⌘R | Ctrl+Shift+R | `!browserFocus` | A |
| `renameWorkspace` | ⇧⌘R | Ctrl+Shift+Alt+R | global | B |
| `editWorkspaceDescription` | ⌥⌘E | Alt+Shift+E | global | C |
| `markWorkspaceDone` | ⌘; | Ctrl+Shift+; | global | A |
| `cycleWorkspaceStatus` | ⇧⌘; | Ctrl+Shift+Alt+; | global | B |
| `toggleChecklistItemComplete` | ⌘↩ | Ctrl+Enter | `todoFocus` | non-terminal context |
| `closeTab` | ⌘W | Ctrl+Shift+W; Ctrl+W | Ctrl+W only `browserFocus \|\| webPanelFocus` | A; frees Ctrl+W in terminals |
| `closeOtherTabsInPane` | ⌥⌘T | Alt+Shift+T | global | C |
| `closeWorkspace` | ⇧⌘W | Ctrl+Shift+Alt+W | global | B |
| `newWorkspaceGroup` | ⌃⌘G | Alt+Shift+G | global | C |
| `groupSelectedWorkspaces` | ⇧⌘G | Ctrl+Shift+Alt+G | global | B; performable: falls through without a multi-selection (as in cmux) |
| `toggleFocusedWorkspaceGroupCollapsed` | ⌃⌘. | Ctrl+Shift+. | global | A |
| `reopenClosedWorkspace` | — | unbound | — | |
| `reopenClosedBrowserPanel` ("Reopen Last Closed") | ⇧⌘T | Ctrl+Shift+Alt+T | global | B |
| `newSurface` | ⌘T | Ctrl+Shift+T | global | A; frees Ctrl+T |
| `toggleTerminalCopyMode` | ⇧⌘M | Ctrl+Shift+M | `terminalFocus` | A (= WT mark mode) |
| `focusTextBoxInput` | ⇧⌘A | Ctrl+Shift+Alt+A | global | B (Ctrl+Shift+A stays select_all) |
| `cycleTextBoxSubmitAction` | ⇧⇥ | Shift+Tab | `textBoxFocus` | non-terminal context |
| `attachTextBoxFile` | ⌥⇧⌘A | Alt+Shift+A | `textBoxFocus` | |
| `sendCtrlFToTerminal`, `pasteLastScreenshot` | — | unbound | — | |
| `sizeTerminalToMyWindow` | ⌃⌥⌘= | n/a | — | multi-client terminal sizing |
| `clearScreenKeepScrollback` | ⇧⌘K | Ctrl+Shift+Alt+K | `terminalFocus` | B |

### A.3 Panes and splits

| Action id | cmux (macOS) | Windows default | Context | Notes |
|---|---|---|---|---|
| `focusLeft/Right/Up/Down` | ⌥⌘←/→/↑/↓ | Ctrl+Alt+←/→/↑/↓ | global | N; performable (passes through without a neighbor) |
| `focusPreviousPane`, `focusNextPane` | — | unbound | — | |
| `focusPaneByNumber` | ⌃⌘1…9 | unbound | — | Ctrl+Alt+digit collides with AltGr on many layouts |
| `splitRight` | ⌘D | Ctrl+Shift+D | global | A |
| `splitDown` | ⇧⌘D | Ctrl+Shift+Alt+D | global | B (fixes today's missing split-down key) |
| `toggleSplitZoom` | ⇧⌘↩ | Ctrl+Shift+Enter | global | A |
| `newPaneAutoLayout` | ⌃⌘N | unbound | — | |
| `increase/decrease/resetWorkspaceTerminalFontSize` | ⌃⌘= / - / 0 | Ctrl+Shift+Alt+= / - / 0 | global | B; Ctrl+= / - / 0 stay per-terminal font size |
| `equalizeSplits` | ⌃⇧⌘= | Alt+Shift+= | global | C |
| `resize-pane-left/right/up/down` | ⌃⇧H / L / K / J | Alt+Shift+←/→/↑/↓ | global | C (WT convention) |
| `splitBrowserRight` | ⌥⌘D | Alt+Shift+D | global | C |
| `splitBrowserDown` | ⌥⇧⌘D | unbound | — | |

### A.4 Canvas and file explorer

| Action id | cmux (macOS) | Windows default | Context | Notes |
|---|---|---|---|---|
| `toggleCanvasLayout` | ⌃⌘C | Ctrl+Shift+Alt+C | global | B |
| `canvasRevealFocusedPane`, `canvasOverview`, `canvasTidy` | ⌃⌘R / ⌃⌘O / ⌃⌘T | unbound | — | palette (W7) |
| `canvasZoomIn/Out/Reset` | ⌥⌘= / ⌥⌘- / ⌘0 | unbound | — | |
| `canvasAlign*`, `canvasEqualize*`, `canvasDistribute*` | — | unbound | — | |
| `toggleFileExplorer` (`toggleRightSidebar`) | ⌥⌘B | Alt+Shift+B | global | C |
| `fileExplorerOpenSelection` | ↩ | Enter | `fileExplorerFocus` | |
| `fileExplorerOpenSelectionFinderAlias` | ⌘↓ | Ctrl+Down | `fileExplorerFocus` | |

### A.5 Panels, browser, find, diff

| Action id | cmux (macOS) | Windows default | Context | Notes |
|---|---|---|---|---|
| `saveFilePreview` | ⌘S | Ctrl+S | `filePreviewTextEditorFocus \|\| markdownEditFocus` | |
| `toggleFileEditorWordWrap` | ⌥Z | Alt+Z | `filePreviewTextEditorFocus` | VS Code convention |
| `openBrowser` | ⇧⌘L | Ctrl+Shift+L | global | A |
| `focusBrowserAddressBar` | ⌘L | Ctrl+L, Alt+D, F6 | `browserFocus` | browser conventions |
| `browserBack` / `browserForward` | ⌘[ / ⌘] | Alt+← / Alt+→, Ctrl+Shift+[ / ], mouse X1 / X2 | `browserFocus` | |
| `browserReload` | ⌘R | F5, Ctrl+R | `browserFocus` | |
| `browserHardReload` | ⇧⌘R | Ctrl+F5, Ctrl+Shift+R | `browserFocus` | |
| `browserZoomIn/Out/Reset` | ⌘= / ⌘- / ⌘0 | Ctrl+= / Ctrl+- / Ctrl+0 | `browserFocus` | |
| `markdownZoomIn/Out/Reset` | ⌘= / ⌘- / ⌘0 | Ctrl+= / Ctrl+- / Ctrl+0 | `markdownFocus` | |
| `find` | ⌘F | Ctrl+Shift+F; Ctrl+F | Ctrl+F only `!terminalFocus` | A; one action routed by context |
| `findInDirectory` | ⇧⌘F | Ctrl+Shift+Alt+F | global | B |
| `findNext` / `findPrevious` | ⌘G / ⌥⌘G | F3, Enter / Shift+F3, Shift+Enter | `findVisible` (Enter forms only in the find field) | F3 not global (htop/mc) |
| `hideFind` | ⌥⇧⌘F | Esc | `findVisible` | |
| `useSelectionForFind` | ⌘E | unbound | — | Ctrl+Shift+E is `focusSidebar` |
| `toggleBrowserDeveloperTools` | ⌥⌘I | F12, Alt+Shift+I | `browserFocus` | |
| `showBrowserJavaScriptConsole` | ⌥⌘C | Alt+Shift+C | `browserFocus` | |
| `toggleBrowserFocusMode` | ⌥⌘↩ | Alt+Shift+Enter | `browserFocus` | exit with double Esc |
| `toggleBrowserDesignMode` | ⌃⌥⌘D | unbound | — | |
| `toggleReactGrab` | ⇧⌘G | Ctrl+Shift+Alt+G | `browserFocus` | shares the chord with `groupSelectedWorkspaces`, which falls through |
| `openDiffViewer` | ⌃⇧⌘D | Ctrl+Shift+G | global | A (VS Code "Source Control" mnemonic) |
| `diffViewerScrollDown` / `Up` | j / k | j / k | `diffViewerFocus` | page-handled |
| `diffViewerScrollHalfPageDown` / `Up` | ⌃D / ⌃U | Ctrl+D / Ctrl+U | `diffViewerFocus` | page-handled |
| `diffViewerScrollDownEmacs` / `UpEmacs` | ⌃N / ⌃P | Ctrl+N / Ctrl+P | `diffViewerFocus` | page-handled |
| `diffViewerScrollToBottom` / `ToTop` | ⇧G / g g | Shift+G / g g | `diffViewerFocus` | chord, page-handled |
| `diffViewerOpenFileSearch` | / | / | `diffViewerFocus` | |
| `diffViewerNextFile` / `PreviousFile` | ] f / [ f | ] f / [ f | `diffViewerFocus` | chords |
| `diffViewerNextHunk` / `PreviousHunk` | n / p | n / p | `diffViewerFocus` | |
| `diffViewerToggleViewed` | v | v | `diffViewerFocus` | |
| `simulator*` | various | n/a | — | iOS simulator |

### A.6 wmux-only actions

| Action id | Windows default | Context | Notes |
|---|---|---|---|
| `wmux.clearScreen` (Ghostty `clear_screen`, cmux's ⌘K) | Ctrl+Shift+K | `terminalFocus` | also a Ghostty win32 default keybind |
| `wmux.pasteFromClipboard` | Ctrl+V | `terminalFocus && !terminalAlternateScreen` | vim keeps ^V visual block in the alternate screen |
| `wmux.toggleQuickTerminal` | unbound (opt-in global) | — | |
| `wmux.toggleSyncInput` | unbound | — | |
| `wmux.selectLayout.evenHorizontal/evenVertical/mainHorizontal/mainVertical/tiled` | unbound | — | |
| `wmux.breakPane`, `wmux.swapPane` | unbound | — | old Ctrl+Shift+! removed |
| `wmux.attentionRing`, `wmux.attentionClear` | unbound | — | legacy notify ring/clear |

### A.7 Terminal keys that remain Ghostty defaults on win32

Ctrl+Shift+C, Ctrl+Insert, Ctrl+C (performable: copies only with a selection) → copy; Ctrl+Shift+V, Shift+Insert (repaired) → paste; Ctrl+Shift+A → select all; Ctrl+= / Ctrl++ / Ctrl+- / Ctrl+0 and Ctrl+wheel → font size; Shift+PgUp/PgDn/Home/End → scroll; Ctrl+Shift+Up/Down → jump to prompt; Esc → end search (performable). Removed old defaults: see ADR-8.7.

---

## Appendix B. v2 RPC method catalog

Names are exactly cmux's (verified against `Sources/TerminalController+Capabilities.swift`). Owner = WP that implements the method; flags noted where not default (`ui` lane, `.mutate`). `polling` methods share the rate limiter; `focus_intent` methods are the only ones that may change selection without `focus:true`. `relay` flags are assigned by W6-4 following cmux's remote relay policy.

### B.1 cmux methods implemented by wmux

| Family | Methods | Owner | Notes |
|---|---|---|---|
| system | `ping`, `capabilities` | W1-1a | `pipe` lane, `.read` |
| | `identify`, `tree` | W2-2 | `.read`, polling, caller resolution |
| | `top`, `memory` | W5a (`task_manager`) | `.read`, polling, job accounting |
| auth | `login` | W1-1b | `pipe` lane (password mode) |
| events | `stream` | W2-4 | `pipe` lane setup, takes over the connection, `deadline_ms = 0` |
| window | `list`, `current` | W2-1 | `.read`, polling |
| | `create`, `close`, `display`, `displays` | W2-1 | |
| | `focus` | W2-1 | `focus_intent` |
| | `screenshot`, `record.start`, `record.stop`, `record.status`, `record.note`, `record.list` | W5b (capture WP, `windows` feature) | local only (never relay) |
| workspace | `list`, `current` | W2-1 | `.read`, polling |
| | `create`, `rename`, `close`, `reorder`, `reorder_many`, `move`, `move_to_window`, `action`, `env`, `equalize_splits` | W2-1 | `create` params: `cwd`, `title`, `description`, `layout`, `workspace_env`, `initial_input`, `initial_command`, `focus` |
| | `select`, `next`, `previous`, `last` | W2-1 | `focus_intent` |
| | `prompt_submit` | W3-4 | |
| | `set_auto_title` | W5b (`auto_naming`) | |
| | `status.get`, `status.set`, `status.cycle` | W5a (`workspace_status`) | |
| | `todo.add`, `todo.clear`, `todo.edit`, `todo.list`, `todo.move`, `todo.open`, `todo.remove`, `todo.set`, `todo.set_state` | W5a (`todo`) | |
| | `group.action`, `group.add`, `group.collapse`, `group.create`, `group.delete`, `group.expand`, `group.focus`, `group.list`, `group.move`, `group.new_workspace`, `group.pin`, `group.remove`, `group.rename`, `group.set_anchor`, `group.set_color`, `group.set_icon`, `group.ungroup`, `group.unpin` | W4-5 (`groups`) | |
| | `ssh.open` | W6-1 | |
| | `remote.configure`, `remote.disconnect`, `remote.foreground_auth_ready`, `remote.pty_attach_end`, `remote.pty_bridge`, `remote.pty_close`, `remote.pty_detach`, `remote.pty_resize`, `remote.pty_sessions`, `remote.reconnect`, `remote.status`, `remote.terminal_session_connected`, `remote.terminal_session_end`, `remote.terminal_session_launching` | W6-1/W6-3 | |
| pane | `list`, `surfaces` | W2-2 | `.read`, polling |
| | `create`, `resize`, `swap`, `break`, `join` | W2-2 | |
| | `focus`, `last` | W2-2 | `focus_intent` |
| surface | `list`, `current` | W2-2 | `.read`, polling |
| | `create`, `split`, `split_off`, `close`, `move`, `reorder`, `drag_to_split`, `action`, `catalog` | W2-2 | `create`/`split` accept `initial_input` / `initial_command` |
| | `focus` | W2-2 | `focus_intent` |
| | `send_text`, `send_key` | W2-3 | `.input`; pending input queue → `input_queue_full` |
| | `read_text`, `read_selection` | W2-3 | `.read`, polling; `read_selection` on the `worker` lane |
| | `refresh`, `health`, `respawn`, `clear_history` | W2-3 | |
| | `trigger_flash` | W2-7 | |
| | `input_state` | W3-1 | `worker` lane, draft guard |
| | `jump_to_last_prompt` | W3-4 | `focus_intent` via `focus:true` |
| | `resume.set`, `resume.get`, `resume.clear` | W3-5 | `approval_required` model |
| | `report_pwd`, `report_git_branch`, `clear_git_branch`, `report_tty`, `report_shell_state`, `ports_kick` | W2-6 | |
| | `sync_codex_native_title` | W3-2 | |
| | `ssh_session_attach.resolve` | W6-3 | |
| tab | `action` | W2-2 | |
| terminal | `paste` | W2-3 | `.input`; 16 MiB line cap |
| | `paste_image` | W5b (`image_paste`) | |
| notification | `create`, `create_for_caller`, `create_for_surface`, `create_for_target`, `list`, `clear`, `dismiss`, `mark_read`, `jump_to_unread`, `open` | W2-5 | `open`, `jump_to_unread`: `focus_intent` |
| | `feed.list`, `feed.mark_read`, `feed.mark_unread`, `feed.mark_all_read` | W5a (`feed`) | |
| feed | `push`, `list`, `jump`, `permission.reply`, `question.reply`, `exit_plan.reply` | W5a (`feed`) | `push` may long-poll (own deadline) |
| agent | `restore.admit`, `restore.release` | W3-5 | |
| | `hibernate`, `wake`, `hibernation.session_end` | W5b (`hibernation`) | |
| | `message.send`, `message.list`, `message.poll`, `message.claim`, `message.ack`, `message.mark_read`, `message.settings`, `resolve_delivery_target` | W5b (`agent_messages`) | |
| app | `focus_override.set`, `simulate_active` | W2-5 | test/debug semantics as cmux |
| browser (core) | `open_split`, `navigate`, `back`, `forward`, `reload`, `url.get`, `get.title`, `get.text`, `get.html`, `get.value`, `get.attr`, `get.count`, `get.box`, `get.styles`, `is.visible`, `is.enabled`, `is.checked`, `find.role`, `find.text`, `find.label`, `find.placeholder`, `find.alt`, `find.title`, `find.testid`, `find.first`, `find.last`, `find.nth`, `snapshot`, `eval`, `click`, `dblclick`, `hover`, `focus`, `type`, `fill`, `press`, `keydown`, `keyup`, `check`, `uncheck`, `select`, `scroll`, `scroll_into_view`, `wait`, `screenshot`, `console.list`, `console.clear`, `errors.list`, `tab.new`, `tab.list`, `tab.switch`, `tab.close`, `dialog.accept`, `dialog.dismiss`, `frame.select`, `frame.main`, `focus_webview`, `is_webview_focused`, `devtools.toggle`, `zoom.set` | W2-8 | async methods use deferred replies; `focus`, `focus_webview`, `tab.switch`: `focus_intent` |
| browser (II) | `console.show`, `cookies.get`, `cookies.set`, `cookies.clear`, `storage.get`, `storage.set`, `storage.clear`, `state.save`, `state.load`, `history.clear`, `download.list`, `download.wait`, `network.requests`, `network.route`, `network.unroute`, `offline.set`, `viewport.set`, `geolocation.set`, `trace.start`, `trace.stop`, `screencast.start`, `screencast.stop`, `input_mouse`, `input_keyboard`, `input_touch`, `addinitscript`, `addscript`, `addstyle`, `highlight`, `react_grab.toggle`, `design_mode.set`, `design_mode.status`, `focus_mode.set`, `profiles.list`, `profiles.create`, `profiles.rename`, `profiles.delete`, `profiles.clear`, `import.cookies`, `import.dialog`, `repl.eval`, `repl.list`, `repl.reset`, `set_input_files` | W5a (`browser`, `browser_profiles`) | |
| file / markdown | `file.open` | W4-2 | |
| | `markdown.open` | W4-1 | |
| layout | `save`, `list`, `get`, `open`, `delete` | W4-7 (`layouts`) | |
| session | `restore_previous` | W1-7 | |
| | `import`, `export` | W4-7 | untrusted-import sanitizer |
| | `agent_recovery.list`, `agent_recovery.restore` | W3-5 | |
| settings | `open` | W4-4 | launches the Settings window |
| sidebar / extension | `sidebar.custom.open`, `extension.sidebar.snapshot` | W5a (`custom_sidebars`) | |
| comments | `list` | W4-3 | |
| current | `list` | W5b (with `global_search`) | |
| vault | `sessions`, `search`, `checkpoints`, `checkpoint`, `fork` | W5a (`vault`) | |
| caffeine | `status`, `set` | W5b (`keep_awake`) | `PowerCreateRequest`/`PowerSetRequest` |
| canvas | `align`, `break`, `info`, `join`, `new_pane`, `overview`, `reveal`, `select_tab`, `set_frame`, `set_mode`, `set_viewport`, `zoom` | W7 (`canvas`) | |
| automation | `list`, `show`, `test`, `enable`, `disable`, `logs`, `reload` | W5a (`automation`) | |
| remote.tmux | `attach`, `attach_progress`, `detach`, `mirror`, `pane_grids`, `pane_surfaces`, `sessions`, `state`, `window` | W6-6 (`remote_tmux`) | |
| debug | `terminals` | W2-3 | |

### B.2 Not supported on Windows (stub → `not_supported {data.reason:"not_available_on_windows"}`; never in capabilities)

`vm.*`, `cloud.*`, `coderouter.*`, `mobile.*`, `auth.*` except `auth.login`, `feedback.*`, `simulator.*`, `ios.*`, `project.*`, `remotes.*`, `workspace.cloud_vm_bind`, `workspace.cloud_vm_open`, `workspace.cloud_vm_terminal_ready`, `surface.new_terminal`, `surface.project`, and the multi-client terminal API `terminal.create`, `terminal.input`, `terminal.mouse`, `terminal.replay`, `terminal.scroll`, `terminal.viewport`, `terminal.size_counts.set`, `terminal.size_policy.set`, `terminal.size_state`, `terminal.size_to_me`, `terminal.participant.disconnect`, `terminal.participants.disconnect_others`.

### B.3 wmux-only methods (`wmux.*`)

| Method | Owner | Purpose |
|---|---|---|
| `app.launch` | W1-1a | launch pipe only: `{intent: open\|new_window\|activate\|uri, argv, cwd, paths, uri}` |
| `wmux.agent.hook` | W3-1 | hook event delivery (`pipe` lane enqueue) |
| `wmux.sidebar.status.set`, `.clear`, `.list`; `wmux.sidebar.progress.set`, `.clear`; `wmux.sidebar.log.append`, `.clear`, `.list`; `wmux.sidebar.state`; `wmux.sidebar.reset` | W2-6 | v2 twins of cmux's v1-only sidebar verbs (`set_status k v --icon --color --priority`, …) |
| `wmux.workspace.pr.set`, `wmux.workspace.pr.clear`, `wmux.workspace.loading` | W2-6 | `cmux pr`, workspace loading spinner |
| `wmux.right_sidebar.get`, `.set`, `.toggle`, `.show`, `.hide`, `.focus` | W1-8 | `right-sidebar` CLI |
| `wmux.window.resize`, `wmux.window.rename` | W2-1 | v1-only `resize_window` |
| `wmux.quick_terminal.toggle` | W2-1 | quick terminal |
| `wmux.config.reload` | W1-4 | v1-only `reload_config` |
| `wmux.settings.schema`, `.get_effective`, `.set`, `.unset`; `wmux.shortcuts.validate`, `.set` | W4-4 | Settings window bridge |
| `wmux.shortcuts.list` | W1-5 | effective bindings |
| `wmux.action.run` | W1-5 | run any action id |
| `wmux.attention.set`, `wmux.notification.toggle_unread`, `wmux.notification.mark_oldest_jump` | W2-5 | legacy notify verbs |
| `wmux.layout.select`, `wmux.sync_input.set` | W2-2 | legacy `select-layout`, `sync-input` |
| `wmux.session.save`, `wmux.surface.resume_run` | W1-7, W3-5 | legacy `session-save`, `session-resume` |
| `wmux.diff.open` | W4-3 | `cmux diff` |
| `wmux.find_window` | W5b | `find-window` |
| `wmux.debug.ready`, `.app.quit`, `.dialogs.list`, `.clipboard.get`, `.clipboard.set`, `.focus_state`, `.layout`, `.type`, `.key` | W1-1 | `test_only` |
| `wmux.debug.sidebar.snapshot` | W1-8 | `test_only` |
| `wmux.debug.web.eval`, `wmux.debug.window.screenshot` | W1-6 | `test_only` (`PrintWindow(PW_RENDERFULLCONTENT)`) |
| `wmux.debug.toasts.list` | W3-7 (sink reader in W2-5) | `test_only` |

### B.4 Legacy wmux JSON command mapping (adapter in each owning feature's `legacy.zig`)

| Legacy cmd | v2 method | Flipped by |
|---|---|---|
| `open` | `browser.open_split` (`target:"tab"` → `surface.create {type:"browser"}`) | W2-8 |
| `navigate`, `eval`, `snapshot`, `click`, `fill` | `browser.navigate`, `browser.eval`, `browser.snapshot`, `browser.click`, `browser.fill` (legacy numeric refs kept) | W2-8 |
| `workspace-list`, `-new`, `-select`, `-close` | `workspace.list`, `.create` (`worktree`/`repo` kept as wmux params), `.select`, `.close` | W2-1 |
| `workspace-set-description` | `workspace.action {action:"set_description"}` | W2-1 |
| `tab-list`, `-new`, `-select`, `-close` | `pane.surfaces`, `surface.create`, `surface.focus`, `surface.close` | W2-2 |
| `surface-list`, `surface-focus` | `surface.list`, `surface.focus` | W2-2 |
| `new-split`, `swap-split`, `break-pane`, `move-pane` | `surface.split`, `pane.swap`, `pane.break`, `surface.move` | W2-2 |
| `select-layout`, `sync-input` | `wmux.layout.select`, `wmux.sync_input.set` | W2-2 |
| `send` | `surface.send_text` (`enter` appends `\r`) | W2-3 |
| `read-screen`, `capture-pane` | `surface.read_text` (`file` kept only in the adapter, access `.exec`, resolved against the client cwd) | W2-3 |
| `notify ring\|clear` | `wmux.attention.set` | W2-5 |
| `notify next\|toggle-read\|mark-oldest-next` | `notification.jump_to_unread`, `wmux.notification.toggle_unread`, `wmux.notification.mark_oldest_jump` | W2-5 |
| `flash-pane` | `surface.trigger_flash` | W2-5 |
| `set-status`, `set-progress`, `log` | `wmux.sidebar.status.set` (key `status`), `wmux.sidebar.progress.set`, `wmux.sidebar.log.append` (no notification any more) | W2-6 |
| `toggle-right-sidebar` | `wmux.right_sidebar.toggle` (target window honored) | W1-8 |
| `session-capture`, `-resume`, `-list`, `-save`, `-restore` | `surface.resume.set`, `wmux.surface.resume_run`, agents store read inside the adapter, `wmux.session.save`, `session.restore_previous` | W1-7 / W3-5 |

---

## Appendix C. CLI command catalog (→ methods → family file → owner)

Command names, aliases and flags are cmux's (`docs/cli-contract.md`); text output follows cmux; every command supports `--help` offline. Family files live in `src/wmux_cli/commands/`; W0-A3 pre-creates them all as stubs listed in `commands/manifest.zig`.

| Help topic | Commands | Method(s) | Family / owner |
|---|---|---|---|
| (global) | `help [topic]`, `--help`, `version`, `--version`, `guide`/`--skill`, `docs [topic]`, `welcome` | local | `system` / W1-2 |
| diagnostics | `ping`, `capabilities`, `rpc <method> [json\|-]` | `system.ping`, `system.capabilities`, any | `system` / W1-2 |
| inspect | `identify`, `tree` | `system.identify`, `system.tree` | `system` / W2-2 |
| inspect | `top`, `memory` | `system.top`, `system.memory` | `system` / W5a |
| diagnostics | `socket-status [--json]` | local (offline) | `system` / W1-2 (data from W1-1b) |
| diagnostics | `debug-terminals`, `surface-health`, `refresh-surfaces` | `debug.terminals`, `surface.health`, `surface.refresh` | `terminal_io` / W2-3 |
| navigate | `list-windows`, `current-window`, `new-window`, `focus-window`, `close-window`, `resize-window`, `window displays`, `window display`, `move-workspace-to-window` | `window.list/current/create/focus/close`, `wmux.window.resize`, `window.displays/display`, `workspace.move_to_window` | `window` / W2-1 |
| start | `list-workspaces`, `new-workspace`, `select-workspace`, `rename-workspace` (`rename-window` alias), `close-workspace`, `current-workspace`, `workspace list\|create\|env\|close\|rename\|select`, `workspace-action`, `reorder-workspace`, `reorder-workspaces`, `next-window`, `previous-window`, `last-window` | `workspace.*` core | `workspace` / W2-1 |
| navigate | `workspace status [set <lane>\|auto]` | `workspace.status.*` | `workspace` / W5a |
| navigate | `workspace reconnect\|disconnect` | `workspace.remote.reconnect/disconnect` | `workspace` / W6-1 |
| navigate | `workspace-group <sub>`, `workspace group <sub>` | `workspace.group.*` | `workspace_group` / W4-5 |
| navigate | `new-split`, `new-pane`, `new-surface`, `close-surface`, `list-panes`, `list-pane-surfaces`, `list-panels`, `focus-pane`, `focus-panel`, `move-surface`, `reorder-surface`, `split-off`, `drag-surface-to-split`, `tab-action`, `rename-tab`, `move-tab-to-new-workspace`/`detach-tab`, `resize-pane`, `swap-pane`, `break-pane`, `join-pane`, `last-pane` | `surface.*`, `pane.*`, `tab.action` | `pane_surface` / W2-2 |
| navigate | `trigger-flash` | `surface.trigger_flash` | `pane_surface` / W2-7 |
| agents | `send`, `send-key`, `send-panel`, `send-key-panel`, `paste`, `read-screen`, `read-selection`, `capture-pane`, `clear-history`, `respawn-pane`, `pipe-pane` | `surface.send_text/send_key/read_text/read_selection/clear_history/respawn`, `terminal.paste` (pipe-pane is client-side) | `terminal_io` / W2-3 |
| agents | `notify`, `list-notifications`, `dismiss-notification`, `mark-notification-read`, `open-notification`, `jump-to-unread`, `clear-notifications`, `set-app-focus`, `simulate-app-active` | `notification.*`, `app.focus_override.set`, `app.simulate_active` | `notify` / W2-5 |
| agents | `jump-to-last-prompt` | `surface.jump_to_last_prompt` | `notify` / W3-4 |
| customize | `set-status`, `clear-status`, `list-status`, `set-progress`, `clear-progress`, `log`, `clear-log`, `list-log`, `sidebar-state`, `pr <url\|number\|clear>`; internal `report_pwd`, `report_git_branch`, `report_pr_action` | `wmux.sidebar.*`, `wmux.workspace.pr.*`, `surface.report_*` | `sidebar_meta` / W2-6 |
| customize | `right-sidebar <sub>` | `wmux.right_sidebar.*` | `right_sidebar` / W1-8 |
| automation | `events [--after --after-seq --cursor-file --name --category --reconnect --limit --no-ack --no-heartbeat]` | `events.stream` | `events` / W2-4 |
| browser | `browser <sub>`, `open-browser`, `navigate`, `browser-back`, `browser-forward`, `browser-reload`, `get-url`, `focus-webview`, `is-webview-focused`, `disable-browser`, `enable-browser`, `browser-status` | `browser.*` (+ settings write for enable/disable) | `browser` / W2-8 (II subcommands W5a) |
| start | `open <path-or-url>...`, `cmux <path>` | `file.open`, `browser.open_split`, `workspace.create`, `app.launch` | `open_files` / W4-2 |
| start | `markdown open <file>` | `markdown.open` | `open_files` / W4-1 |
| inspect | `diff [...]`, `comments list`, `review` | `wmux.diff.open`, `comments.list` (offline fallback reads the store), local | `open_files` / W4-3 |
| customize | `config <sub>`, `reload-config`, `themes [list\|set\|clear]`, `settings path\|docs` | local (offline), `wmux.config.reload` | `config` / W1-4 |
| customize | `settings [open] [target]`, `shortcuts` | `settings.open` (launch if needed) | `config` / W4-4 |
| customize | `import [terminal] [--dry-run --path --yes --json]` | local (Ghostty overlay writes) | `config` / W7 |
| start | `restore-session [--from <channel\|path>] [--export <path> [--force]]` | `session.restore_previous`, `session.import/export` | `session` / W1-7 (import/export W4-7) |
| agents | `hooks <sub>`, `setup-hooks`, `uninstall-hooks`, `codex install\|uninstall`, `claude-hook`, `codex-hook`, `feed-hook`, `sessions [list]`, `session-debug` | local store + `wmux.agent.hook` | `hooks_agents` / W3-1 (installers W3-3) |
| agents | `surface-resume <show\|set\|clear>` (`surface resume …`), `restore`, `fork`, `session restore [--list] [--session id]` | `surface.resume.*`, `session.agent_recovery.*`, local spawn | `hooks_agents` / W3-5 |
| agents | `agent message\|inbox\|messages`, `agent hibernate\|wake`, `agent-hibernation` | `agent.message.*`, `agent.hibernate/wake`, settings | `hooks_agents` / W5b |
| agents | `claude-teams`, `codex-teams`, `omo`, `omx`, `omc`, `__tmux-compat`, `wait-for`, `__debug-tmux-compat-env` | client-side translation onto v2 | `teams` / W3-6 |
| automation | `layout save\|list\|get\|open\|delete` | `layout.*` | `layout_todo` / W4-7 |
| automation | `todo <sub>`, `feed [tui\|clear]`, `vault <sub>`, `automation <sub>` | `workspace.todo.*`, `feed.*`, `vault.*`, `automation.*` | `layout_todo` / W5a |
| inspect | `current`, `find-window` | `current.list`, `wmux.find_window` | `layout_todo` / W5b |
| inspect | `shot`/`screenshot`, `record <sub>` | `window.screenshot`, `window.record.*` | `window` / W5b |
| remote | `ssh`, `mosh`, `mosh-tmux`, `ssh-tmux`, `ssh-session-list\|attach\|cleanup`, `remote-daemon-status`, internal `ssh-pty-attach`, `ssh-session-end`, `__ssh-*` | `workspace.ssh.open`, `workspace.remote.*`, `remote.tmux.*`, local manifest | `remote` / W6 |
| remote | `local-tmux <sub>`, `tmux attach`, `local-zellij <sub>` | local (WSL) | `remote` / W7 |
| customize | `canvas <sub>` | `canvas.*` | `canvas` / W7 |
| diagnostics | `sudo <command>` | UAC-brokered approval (`extra-sudo-approval-broker`) | `system` / W7 |
| (wmux) | `wmux attention ring\|clear`, `wmux notification toggle-unread\|mark-oldest-jump`, `wmux quick-terminal toggle`, `wmux layout select <name>`, `wmux sync-input on\|off\|toggle`, `wmux session save\|resume`, `wmux action run <id> [arg]`, `wmux install-cli\|uninstall-cli` | `wmux.*` (Appendix B.3) | `wmux_ns` / owners per row in B.3; framework W1-2; install-cli W7 |
| not supported | `vm`, `cloud`, `agent <claude\|codex\|opencode\|pi> …` (vm form), `vpn`, `remotes`/`remote`, `mobile`, `auth`/`login`/`logout`, `billing`, `ai-accounts`, `coderouter`/`cr`, `iroh-diag`, `feedback`, `project`, `simulator`, `ios`, `glaeda`, `recover`, `session move`, `vm-*` internals | — | print `not supported on wmux (requires cmux cloud/macOS)`, exit 2 / W1-2 |

Families (pre-seeded stubs): `system window workspace workspace_group pane_surface terminal_io notify sidebar_meta right_sidebar events browser open_files config session hooks_agents teams layout_todo remote canvas wmux_ns legacy_plus` (the `+verb` mapping table of ADR-4.11 lives in `legacy_plus`, owned by W1-2).

---

## Appendix D. End-to-end harness specification (`test/e2e/`)

### D.1 Files

| File | Purpose |
|---|---|
| `test/e2e/WmuxTest.psm1` | the helper module (PowerShell 7, no external modules, no Pester) |
| `test/e2e/run.ps1` | runner: discovery, parallelism, retries, JUnit + JSON output |
| `test/e2e/coverage.ps1` | parity coverage from `# covers:` tags vs `matrix.csv` |
| `test/e2e/suites/<area>/<wp-id>.e2e.ps1` | test files (areas = matrix areas: core, sidebar, notifications, browser, cli, agents, persistence, panels, remote, extra; plus `smoke`, `_quarantine`) |
| `test/e2e/fixtures/` | static inputs (golden JSON shapes, sample repos, files to preview) |
| `test-results/` | `e2e.json`, `e2e.junit.xml`, per-test artifacts (gitignored) |

### D.2 Instance isolation (what `Start-WmuxInstance` sets up)

1. `$id = [guid]::NewGuid().ToString('N').Substring(0,8)`; root `$env:RUNNER_TEMP` or `$env:TEMP` + `\wmux-e2e\<id>` with `state\`, `config\`, `xdg\`, `artifacts\`.
2. `config\wmux.json` = `{ "automation": { "socketControlMode": "automation" } }` deep-merged with `-Settings` (dotted keys expanded, e.g. `@{ 'sidebar.showPorts' = $false }`).
3. `ghostty.conf` = `-Ghostty` lines plus `command = <shell>` (default `cmd.exe /d /k prompt WMUX$G`, a deterministic prompt; tests needing pwsh pass `-Shell 'pwsh.exe -NoLogo -NoProfile'`).
4. Child environment: `WMUX_TEST_MODE=1`, `WMUX_TEST_HIDDEN=1` (omitted only with `-Visible`, for local debugging), `WMUX_CHANNEL=test-<id>`, `WMUX_STATE_DIR=<root>\state`, `WMUX_CONFIG_DIR=<root>\config`, `XDG_CONFIG_HOME=<root>\xdg` (isolates `cmux.json` and Ghostty user config), `WMUX_SOCKET_MODE=automation`, `WMUX_DISABLE_SESSION_RESTORE=1` (with `-Restore`: `WMUX_TEST_SESSION_RESTORE=1` instead), `WMUX_TEST_TOAST_SINK=<root>\toasts.jsonl`; inherited `CMUX_*`, `WMUX_SOCKET_*` and `GHOSTTY_*` from the harness's own terminal are removed.
5. Launch `<exe> --config-default-files=false --config-file=<root>\ghostty.conf` with `ProcessStartInfo` (`UseShellExecute=false`, `CreateNoWindow=true`); the app itself shows windows with `SW_SHOWNOACTIVATE` off-screen.
6. Wait (≤ `-TimeoutSec`, default 30): read `state\run\instance.json` or compute the pipe name with the same algorithm as `wmux_proto/pipe_name.zig` (`wmux-test-<id>-<sidhash8>-s<session>`), poll `NamedPipeClientStream.Connect(100)`, then poll `wmux.debug.ready` until `{ready:true}`.
7. Start the focus sampler: every 100 ms, `GetWindowThreadProcessId(GetForegroundWindow())`; if it ever equals the instance PID, the current test fails with `focus stolen by test instance` (robust to the user switching windows while tests run).

### D.3 Exported functions

```powershell
Start-WmuxInstance  [-Build Debug|Release] [-Exe <path>] [-Settings <hashtable>] [-Ghostty <string[]>] [-Shell <string>]
                    [-Restore] [-Visible] [-KeepArtifacts] [-TimeoutSec 30]                       # → [WmuxInstance]
Stop-WmuxInstance   [WmuxInstance] [-TimeoutSec 5]        # wmux.debug.app.quit → wait → taskkill /T /F; collect artifacts on failure; delete root
Invoke-WmuxRpc      [WmuxInstance] <method> [<hashtable params>] [-TimeoutSec 15] [-Raw]          # → result | throws [WmuxRpcError] (.Code, .Message, .Data)
Invoke-WmuxRawLine  [WmuxInstance] <line> [-TimeoutSec 15]                                         # → reply line (legacy JSON or text-v1)
Invoke-WmuxCli      [WmuxInstance] <string[] args> [-Stdin <string>] [-Env <hashtable>] [-AsWmux] # runs cli\cmux.exe (or wmux.com) with WMUX_SOCKET_PATH set → @{ ExitCode; Stdout; Stderr }
Open-WmuxEventStream  [WmuxInstance] [-Category <string[]>] [-Name <string[]>] [-AfterSeq <long>]  # → [WmuxEventStream] (background reader)
Read-WmuxEvents       [WmuxEventStream] [-TimeoutSec 5]                                            # → frames received so far
Close-WmuxEventStream [WmuxEventStream]
Wait-WmuxEvent      [WmuxInstance] (-Name <event> | -Category <cat>) [-Where <scriptblock>] [-TimeoutSec 10]   # → event frame | throws
Wait-WmuxCondition  [-TimeoutSec 10] [-IntervalMs 100] <scriptblock>                               # polls until truthy | throws
Wait-WmuxScreen     [WmuxInstance] -Surface <id> -Pattern <regex> [-TimeoutSec 10]                 # polls surface.read_text
Get-WmuxScreenshot  [WmuxInstance] -Path <png> [-Window <id>]                                      # wmux.debug.window.screenshot
Get-WmuxToasts      [WmuxInstance]                                                                  # parsed toast sink
Get-WmuxDialogs     [WmuxInstance]                                                                  # wmux.debug.dialogs.list
Assert-Equal <expected> <actual> [-Message]   Assert-NotEqual   Assert-Match <regex> <string>   Assert-True <bool>
Assert-Throws -Code <errorCode> <scriptblock>   Assert-JsonShape <object> <shape>   # shape: golden JSON; UUID/ref/timestamp values wildcarded
Test-Case <name> <scriptblock>                                                       # timing, result capture, focus-sampler check
```

`[WmuxInstance]` fields: `Pid`, `Channel`, `Root`, `StateDir`, `ConfigDir`, `Pipe`, `LaunchPipe`, `Exe`, `CliExe`, `ToastSink`, `ArtifactsDir`, `Failed`.

### D.4 Test file template

```powershell
# wp: W2-1
# covers: core-workspace-create, core-cli-new-workspace
# manual: core-workspace-create-plus-button "pointer click on the sidebar footer button; covered by UI dogfood checklist"
Import-Module (Join-Path $PSScriptRoot '..\..\WmuxTest.psm1') -Force

Test-Case 'workspace.create returns handles and keeps focus' {
    $w = Start-WmuxInstance
    try {
        $before = Invoke-WmuxRpc $w 'wmux.debug.focus_state'
        $ws = Invoke-WmuxRpc $w 'workspace.create' @{ title = 'e2e'; focus = $false }
        Assert-Match '^workspace:\d+$' $ws.workspace_ref
        Wait-WmuxEvent $w -Name 'workspace.created' -Where { $_.workspace_id -eq $ws.workspace_id } | Out-Null
        $after = Invoke-WmuxRpc $w 'wmux.debug.focus_state'
        Assert-Equal $before.workspace_id $after.workspace_id
        $cli = Invoke-WmuxCli $w @('list-workspaces', '--json')
        Assert-Equal 0 $cli.ExitCode
        Assert-True (($cli.Stdout | ConvertFrom-Json).workspaces.workspace_id -contains $ws.workspace_id)
    } finally { Stop-WmuxInstance $w }
}
```

### D.5 Runner and outputs

`pwsh test/e2e/run.ps1 [-Suite <glob>] [-Filter <text>] [-Parallel 4] [-Build Debug|Release] [-Quarantine] [-NoRetry]` discovers `suites/**/*.e2e.ps1` (skipping `_quarantine` unless `-Quarantine`), runs each file in its own `pwsh` process (`ForEach-Object -Parallel`), retries a failed file once and marks it flaky, aggregates `Test-Case` results into `test-results/e2e.json` and `e2e.junit.xml`, copies artifacts (screenshots, `events.jsonl`, logs, toast sink, dialogs log) for failures, and exits 1 on any failure. Per-test timeout 120 s; whole-suite budget enforced by the gate.

The smoke suite (`suites/smoke/smoke.e2e.ps1`, W0-B, upgraded in W1/W2) covers: `system.ping`, `system.capabilities`, `system.tree`, workspace create/close, send + read-screen, `cli\cmux.exe ping`, `events.stream` ack. Before W1-1a it uses the legacy JSON protocol through `Invoke-WmuxRawLine`.

`coverage.ps1` joins `# covers:`/`# manual:` tags with the in-scope ids of `matrix.csv` and prints coverage per area, the list of uncovered critical ids, and stale tags (ids not in the matrix).

---

## Appendix E. Windows deviations from cmux (complete list)

| # | cmux | wmux on Windows |
|---|---|---|
| D1 | Unix socket under `~/Library/…`; `nc -U` clients | named pipe `\\.\pipe\wmux-<channel>-<sidhash8>-s<session>`; `CMUX_SOCKET_PATH` holds it; raw Unix-socket clients unsupported (use `cmux rpc` or a named-pipe client) |
| D2 | `cmux` binary inside the app bundle, CLI forwarding | `cli\cmux.exe` + `cli\wmux.com` + sh launchers; GUI `wmux.exe` relays CLI argv; the installer never edits PATH; `cmux install-cli` uses forwarders in an existing PATH dir |
| D3 | `exec()` | wrappers, `restore`, `fork` spawn the child in the same console inside a kill-on-close job and propagate the exit code |
| D4 | Cmd-based shortcuts | Appendix A tiers; AltGr "text always wins"; Alt+digit and other terminal keys never claimed; `cmux.json` mac strokes translated with collision reports; explicit Ghostty keybinds beat router defaults |
| D5 | `~/.cmuxterm/*` state; settings UserDefaults below `cmux.json` | `%LOCALAPPDATA%\wmux\<channel>\…`; `wmux.json` above `cmux.json`; the Settings UI writes `wmux.json` (no third store) |
| D6 | macOS notification center, bundle id | WinRT toasts under AUMID `wmux.app[.<channel>]` with `wmux:` protocol activation, COM activator for Reply, balloon fallback; sound names mapped to Windows sound events, self-played |
| D7 | `cmuxOnly` via socket peer ancestry | job membership ∨ creation-time-verified ancestry ∨ capability envelope; `caller_tty` replaced by client-PID job lookup |
| D8 | runtime vs stable ids | one identity per object; `stable_*` fields equal the normal ids |
| D9 | shell-integration `cat` for scrollback restore | terminal-side replay before the shell starts (works for cmd) |
| D10 | tmux window → tab with in-tab splits | tmux session → group, window → workspace, pane → pane |
| D11 | ControlMaster connection sharing | one carrier `ssh.exe` per route |
| D12 | WKWebView session-state blob; SOCKS with auth | app-side back/forward list; SOCKS5 with PID admission per remote WebView2 environment |
| D13 | Swift custom sidebars | JS and JSON dialects only |
| D14 | Mac-only settings keys | accepted, ignored, reported by `config doctor` |
| D15 | — | server-side `*_id` params also accept JSON integer indexes |
| D16 | — | extra access mode `readOnly` |
| D17 | `TERM=xterm-ghostty` | `TERM=xterm-256color` unless Ghostty `term` is explicitly set |
| D18 | Quick terminal, sync input, select-layout absent | kept as `wmux.*` methods and actions |
| D19 | cloud, account, mobile, simulator, Xcode, iroh | `not_supported` (methods) / exit 2 (CLI) |
| D20 | macOS memory-pressure signal | `CreateMemoryResourceNotification` for hibernation safety (W5) |
| D21 | Ghostty tab actions | mapped to workspaces by default (`wmux.ghosttyTabActions`) |
| D22 | diff viewer local HTTP server | WebView2 virtual hosts / `WebResourceRequested`; `diff-viewer-server` not needed |
| D23 | `mosh` | `not_supported` unless `wmux.remote.moshCommand` is configured |

---

## Appendix F. Verification notes and document history

### F.1 Conflicts between the proposals, resolved against code and cmux sources

1. **PATH**: all three proposals assumed an installer PATH option; `dist/windows/installer.iss` forbids touching PATH ("ABSOLUTE RULE"). → ADR-4.2 (runtime prepend + `install-cli` forwarders).
2. **Capability token transport**: cmux uses the line prefix `_cmux_capability_v1 <token> ` and `CMUX_SOCKET_CAPABILITY` (`CmuxControlSocket/Transport/SocketClientCapabilityEnvelope.swift`); the proposed JSON `capability` field was dropped.
3. **cmuxOnly semantics**: cmux admits descendants, or same-user peers with a valid capability per line (`SocketClientAuthorization.swift`). wmux keeps that and widens "descendant" with job membership.
4. **Caller context**: `caller {workspace_id, surface_id|tab_id}` and `caller_tty` live inside `params` (`TerminalController.swift`, `CLI/cmux.swift`); a top-level field was dropped.
5. **`CMUX_TAB_ID`** is the workspace UUID and `CMUX_PANEL_ID` the surface alias (`RemoteTmuxController.swift`, `CmuxTopSnapshotScopeCache.swift`); no `WMUX_TAB_ID` to avoid confusing wmux "tabs".
6. **Lanes**: cmux documents worker-lane methods (`surface.input_state`, `surface.read_selection`) → `Lane.worker` exists.
7. **Capabilities shape** verified `{protocol, version, socket_path, access_mode, capabilities, methods}`; `caffeine.*` is a cmux family (not a wmux extra); all 33 error codes exist in cmux.
8. **Text-v1 priority**: cmux's own CLI speaks v1 for many commands (`set_status`, `list_windows`, …) but cannot run on Windows; text-v1 matters only for raw-socket tooling → framework in W1, verbs in W5, `wmux.*` v2 twins for v1-only commands.
9. **ssh-tmux mapping**: wmux has no splits inside a tab (ui-model invariant 15) → session→group, window→workspace, pane→pane; the window→tab mapping was rejected.
10. **Server threading**: thread-per-connection over IOCP (≤64 clients, in-order replies by construction, deadline = wait timeout).
11. **`socket-control` default** is `.on` in `Config.zig`; reading it as a fallback would defeat the `cmuxOnly` default → only explicitly-set values count (`Config._replay_steps`).
12. **Full test suite** has known environment failures (CI comment in `windows-ci.yml`) → gates use the `unit: ` filter set plus `test/known-failures.txt`.
13. **Alt+digit**: PSReadLine and readline bind digit-argument → no Alt+1..9 defaults; `Ctrl+Shift+1..9` loses nothing typeable.
14. **Ctrl+Alt+letter** collides with AltGr text on common layouts (Polish ą ć ę ł ń ó ś ź ż; German € @ µ) → no Ctrl+Alt+letter defaults; "text always wins".
15. **Spawn path**: processes start in `src/Command.zig` (`startWindows`, a one-attribute list); `env_override` is applied in `Exec.zig` after the apprt env → job attribute in `Command.zig`, protected env applied after `env_override`.
16. **Broadcasts**: message-only windows do not receive `WM_QUERYENDSESSION`/`WM_POWERBROADCAST`/`WM_SETTINGCHANGE` → hidden top-level broadcast window.
17. **Toast Tag/Group** limit is 64 characters → full UUIDs.
18. **Hook store writer**: cmux's hook CLI writes `~/.cmuxterm/<agent>-hook-sessions.json` (`docs/agent-hooks.md`) → the CLI writes; the app reads/prunes.
19. **cmux.json schema** sections verified (`automation.socketPassword`, `terminal.autoResumeAgentSessions`, `notifications.suppress*`, `shortcuts.{bindings,when,showModifierHoldHints}`) → keys absent from cmux's schema live under `wmux.*` (`wmux.sidebar.visible|width`, `wmux.rightSidebar.visible|width` — cmux's `rightSidebar` section only has `beta` —, `wmux.browser.enabled`, `wmux.notifications.desktop|commandShell|desktopBackend|flashTaskbar|historyLimit`, `wmux.ghosttyTabActions`, `wmux.agents.preserveAuthEnv`, `wmux.remote.moshCommand`).
20. **WebView2**: one environment with a `wmux-ui` profile (shared browser process) instead of a second environment; remote routes need their own environment because the proxy is an environment argument.
21. **Registries**: no configure-time codegen (writes into the source tree race with parallel builds/tooling); explicit pre-seeded `ext` fields instead of `@Type` reification (available in 0.15.2 but unnecessary).
22. **Ghostty isolation flag** `config-default-files` exists in `Config.zig` → harness isolation.
23. **Feature placement**: W0 moves IPC handlers into per-feature `legacy.zig` files (not one shared legacy file) so W2 WPs flip their own commands without conflicts.

### F.2 Document history

| Date | Change |
|---|---|
| 2026-10-15 | Initial authoritative version (merged from the compat, native and delivery proposals with verification). |
| 2026-10-15 | Lead-architect amendments from the W0-D spikes (these override any WP prompt that still says otherwise): (1) ADR-12.3 `WMUX_TEST_HIDDEN` uses DWM cloaking inside the work area instead of (-32000,-32000) placement (S2); (2) ADR-14.3 link list drops `runtimeobject`/`combase`, WinRT via api-set externs (S1); (3) ADR-4.1 CLI layout adds `cli\wmux.exe` and moves the sh launchers to `cli\posix\` (S4, S6; CCR `docs/arch/ccr/W1-2a-1.md` when implemented). Read all spike notes in `docs/arch/spikes/` before implementing a consumer WP. |

---

## Appendix G. Paths and environment reference

### G.1 Paths

| Name | Resolution | Contents |
|---|---|---|
| `INSTALL` | directory of `wmux.exe` (default `%LOCALAPPDATA%\Programs\wmux`) | `wmux.exe`, `WebView2Loader.dll`, `share\`, `cli\` |
| `CLI` | `INSTALL\cli` | `cmux.exe`, `wmux.com`, `cmux`, `wmux` (LF sh) |
| `SHARE` | `INSTALL\share` | `ghostty\…` (existing resources), `wmux\web\`, `wmux\schema\wmux.schema.json`, `wmux\shell-integration\`, `wmux\icons\` |
| `CONFIG` | `%WMUX_CONFIG_DIR%` → `%XDG_CONFIG_HOME%\wmux` → `%USERPROFILE%\.config\wmux` | `wmux.json`, `config.ghostty` (overlay), `sidebars\`, `layouts\` |
| `CMUX_CONFIG` | `%XDG_CONFIG_HOME%\cmux` → `%USERPROFILE%\.config\cmux` | `cmux.json`, `sidebars\` (read-only compat) |
| `STATE` | `%WMUX_STATE_DIR%` → `%LOCALAPPDATA%\wmux\<channel>` | `run\` (`instance.json`, `handles.json`, `socket-capability.bin`, `socket-control-password.bin`, `settings-overrides.ghostty`), `session\`, `events\`, `agents\` (stores, `spool\`, `claude-settings\`, `tmux-compat-store.json`, `agent-integrations.json`), `shims\<build-id>\{agents,teams}\`, `webview2\`, `trust\` (`projects.json`, `resume-approvals.json`, `remote-images.json`), `history\`, `logs\`, `wait-for\`, `tmux\`, `palette-usage.json` |
| legacy | `%LOCALAPPDATA%\ghostty\` | `config.ghostty` (still the Ghostty config), `session-state.json` (migrated once), `window-state` (seeds placement), `webview2\` (moved once), `scrollback\` (dead; ignored) |

### G.2 Environment variables

| Variable | Read by | Meaning |
|---|---|---|
| `WMUX_CHANNEL`, `WMUX_TAG` | app, CLI | channel override / `dev-<tag>` |
| `WMUX_STATE_DIR`, `WMUX_CONFIG_DIR`, `XDG_CONFIG_HOME` | app, CLI | path overrides |
| `WMUX_WEB_DIR`, `WMUX_WEB_DEVTOOLS` | app | live web assets; panel DevTools |
| `WMUX_TEST_MODE`, `WMUX_TEST_HIDDEN`, `WMUX_TEST_TOAST_SINK`, `WMUX_TEST_SESSION_RESTORE` | app | test mode (ADR-12.3) |
| `WMUX_DISABLE_SESSION_RESTORE`, `CMUX_DISABLE_SESSION_RESTORE` | app | skip restore |
| `WMUX_SOCKET_MODE`/`CMUX_SOCKET_MODE`, `WMUX_SOCKET_ENABLE`/`CMUX_SOCKET_ENABLE` | app | access-mode overrides |
| `WMUX_SOCKET_PASSWORD`/`CMUX_SOCKET_PASSWORD` | app, CLI | password mode |
| `WMUX_SOCKET_PATH`/`CMUX_SOCKET_PATH`, `CMUX_SOCKET` (deprecated) | CLI | explicit pipe |
| `WMUX_SOCKET_CAPABILITY`/`CMUX_SOCKET_CAPABILITY` | CLI | capability prefix |
| `CMUX_WORKSPACE_ID`, `CMUX_SURFACE_ID`, `CMUX_TAB_ID` (+ `WMUX_` twins where defined) | CLI, hooks | default context |
| `WMUX_CLI_RESPONSE_TIMEOUT_SEC`/`CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC` | CLI | response timeout |
| `WMUX_APP_STARTUP_WAIT_TIMEOUT_SECONDS`/`CMUX_APP_STARTUP_WAIT_TIMEOUT_SECONDS` | CLI | launch wait (can only shorten) |
| `WMUX_FOCUS_NEW`/`CMUX_FOCUS_NEW`, `WMUX_QUIET`/`CMUX_QUIET` | CLI | focus default; legacy-verb notice |
| `WMUX_ARGV0` | CLI | branding when launched through sh launchers |
| `CMUX_<AGENT>_HOOKS_DISABLED`/`WMUX_<AGENT>_HOOKS_DISABLED` | hooks, wrappers | disable an integration |
| terminal outputs | shells | ADR-3.9 table |

---

## Appendix H. Work-package spec template (`docs/arch/wp/<id>.md`)

```markdown
---
id: W2-5
title: Notifications core
wave: 2
size: L                      # S < 1 agent-day, M 1-2, L 2-4 (XL must be split)
depends: [W1-1, W1-4, W1-8]
covers:                      # matrix.csv ids; each needs an e2e `# covers:` tag or a `# manual:` waiver
  - notifications-store-model
  - notifications-unread-model
owns:                        # globs this WP may create/modify
  - src/apprt/win32/features/notifications/**
  - src/wmux_proto/settings/specs/notifications.zig
  - src/wmux_cli/commands/notify.zig
  - test/e2e/suites/notifications/W2-5*.e2e.ps1
  - docs/wmux/features/notifications.md
  - changes/W2-5.md
touches:                     # hot/frozen files, each with the reason (must match the wave's hot-file table)
  - path: src/apprt/surface.zig
    reason: heap notification payload in the surface message
appends:                     # shared-appendable files
  - src/wmux_proto/events_catalog.zig
apis_needed: []              # other features' api.zig functions (stubbed by the wave interface commit)
ccr: []                      # docs/arch/ccr/<wp>-<n>.md
deviations: []               # Appendix E rows requested
---

## Design notes
Links to ADR sections; decisions specific to this WP; acceptance lines taken from inventory/<area>.json.

## Tests
Unit test names (`unit: notifications: …`), e2e suite paths, manual waivers with reasons.

## Done when
`scripts/gate.ps1 -Wp W2-5` green; `coverage.ps1` shows every listed id covered or waived; docs and changelog fragment written.
```
