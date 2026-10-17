# cmux guide

wmux is a Windows terminal for AI coding agents. The `cmux` and `wmux`
commands drive it over a per-user named pipe; inside wmux terminals they are
already on PATH and know which workspace and surface they run in.

## Find your target

The model is window > workspace > panes > surfaces (tabs). Every object has
a UUID and a short ref such as `workspace:2` or `surface:5`; commands accept
either, or a positional index.

- `cmux identify --json`: the app, its version and the caller's own
  workspace and surface.
- `cmux tree --all --json`: every window, workspace, pane and surface.
- `cmux capabilities --json`: the methods this app supports.

Without explicit flags, commands act on the caller's workspace and surface
(`CMUX_WORKSPACE_ID`, `CMUX_SURFACE_ID`), never on whatever happens to be
focused. Commands run by an agent stay in the background.

## Work with terminals

- `cmux new-workspace --name api --cwd C:\src\api --command "npm test"`
- `cmux new-pane` or `cmux new-split right` next to the caller.
- `cmux read-screen --surface surface:5 --lines 40` reads terminal text.
- `cmux send --surface surface:5 "git status\n"` types text;
  `cmux send-key --surface surface:5 enter` presses one key.
- `cmux notify --title "Build" --body "done"` raises a notification.

## Use the browser

`cmux browser ...` drives wmux's built-in browser panes (open, navigate,
snapshot, click, fill, screenshot). Prefer it over an external headless
browser when the page should stay visible to the user.

## Scripting notes

- `--json` prints machine-readable results; `--id-format refs|uuids|both`
  picks the handle style.
- `cmux rpc <method> '<json>'` calls any v2 method; pass `-` to read the
  params from stdin.
- `cmux help <topic>` lists commands by task; `cmux <command> --help` works
  without a running app.

Cloud machines, computer use and other cmux cloud or macOS features are not
available on wmux.
