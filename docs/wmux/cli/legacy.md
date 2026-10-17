# Legacy `+verbs` and the two-binary CLI

wmux ships two programs:

| File | Subsystem | Role |
|---|---|---|
| `wmux.exe` (install directory) | GUI | the terminal app; also runs Ghostty's own `+actions` |
| `cli\cmux.exe`, `cli\wmux.exe`, `cli\wmux.com` | console | the command-line client (byte copies; the name picks the branding) |
| `cli\posix\cmux`, `cli\posix\wmux` | sh | launchers for Git Bash, MSYS2 and WSL that run `..\cmux.exe` |

Inside wmux terminals `cli\` is on PATH. Elsewhere, call the files by path (the installer never
edits PATH).

## Which binary runs what

`wmux.exe` looks at its arguments before starting the app:

| Arguments | What happens |
|---|---|
| a Ghostty action: `+version`, `+help`, `+list-themes`, `+list-fonts`, `+list-keybinds`, `+list-colors`, `+list-actions`, `+show-config`, `+explain-config`, `+validate-config`, `+edit-config`, `+show-face`, `+crash-report`, `+boo`, `+ssh`, `+ssh-cache`, `+hooks`; also `--version` and `--help` | runs inside `wmux.exe` |
| a legacy wmux verb (`+workspace`, `+tab`, `+send`, `+notify`, `+surface`, `+split`, `+status`, `+log`, `+read-screen`, `+capture-pane`, `+session`, `+browser`, `+new-window`, `+toggle-quick-terminal`) | relayed to `cli\cmux.exe` |
| a cmux command (`wmux.exe list-workspaces --json`, `wmux.exe help`, `wmux.exe wmux attention ring`) or a cmux global option first (`--socket`, `--password`, `--window`, `--json`, `--id-format`) | relayed to `cli\cmux.exe` |
| anything else (`--new-window`, `-e cmd.exe`, config flags, no arguments) | starts the app (or hands the request to the running instance) |

The relay starts `cli\cmux.exe` with the same arguments and the same standard input, output and
error, waits for it and exits with its exit code. When `wmux.exe` has no standard handles (it is
a GUI program started from an interactive console) it attaches to the parent console first. An
interactive `cmd.exe` does not wait for GUI programs, so its prompt can come back before the
output: use `cli\wmux.com` (or `cli\cmux.exe`) in consoles. Piped and redirected calls
(`wmux.exe list-workspaces --json | Out-String`, scripts, agents) work either way.

`cli\cmux.exe` in turn relays the Ghostty actions above to `..\wmux.exe`, so `cmux +version`
and `wmux +list-themes` work from either binary and return that program's exit code.

## Legacy `+verbs` keep their output

Scripts written for the old wmux CLI keep working unchanged: every legacy `+verb`, through
`wmux.exe` or through `cli\wmux.com`/`cli\cmux.exe`, prints exactly what it printed before
(stdout byte for byte, the same stderr messages and exit codes). The verbs accept their old
arguments and flag meanings, for example:

- `+status set <text>`, `+status progress 0-100|clear` (values above 100 are an error),
- `+send <text> [--enter] [--workspace I] [--tab J] [--pane P]` with flags anywhere,
- `+notify next`, `+notify toggle-read`, `+notify mark-oldest-next`,
- `+browser open <url> [--tab|--split]`, `+browser eval <js> [--id N]`,
- `+capture-pane [--file <path>] [--scrollback]`,
- `+tab close <index> [--pane P]`, `+surface focus [<id>] [--workspace I] [--tab J] [--pane P]`.

The verbs talk to the instance over its legacy pipe `\\.\pipe\wmux-ipc-<pid>`, found exactly as
before: `GHOSTTY_PID` (set in every wmux terminal), otherwise the only `wmux-ipc-*` pipe.

When no legacy pipe exists at all (no wmux instance runs, and later releases that drop the
legacy pipe), a `+verb` is served by the equivalent cmux command instead and prints that
command's output, after a one-line notice naming the new command (silence it with
`WMUX_QUIET=1` or `CMUX_QUIET=1`):

| Legacy | cmux command |
|---|---|
| `+workspace list\|new\|select\|close` | `list-workspaces`, `new-workspace`, `select-workspace`, `close-workspace` |
| `+tab list\|new\|select\|close` | `list-pane-surfaces`, `new-surface`, `focus-panel`, `close-surface` |
| `+surface list\|focus` | `list-panels`, `focus-panel` |
| `+split <dir>` | `new-split <dir>` |
| `+send <text> [--enter]` | `send` |
| `+notify ring\|clear\|next\|toggle-read\|mark-oldest-next` | `wmux attention ring\|clear`, `jump-to-unread`, `wmux notification toggle-unread`, `wmux notification mark-oldest-jump` |
| `+status set\|progress` | `set-status`, `set-progress` |
| `+log`, `+read-screen`, `+capture-pane`, `+browser <sub>` | `log`, `read-screen`, `capture-pane`, `browser <sub>` |
| `+session capture\|resume\|show\|save\|restore` | `surface-resume set`, `wmux session resume`, `sessions`, `wmux session save`, `restore-session` |

New scripts should use the cmux commands directly (`wmux help` lists them).

## `+verb --help`

The legacy verbs never had their own help text: `wmux +workspace --help` prints
`error: ActionHelpRequested` and exits 1, as it always did, whether or not wmux is running.
`+new-window` and `+toggle-quick-terminal` are not supported on Windows and exit 1 (the first
prints `+new-window is not supported on this platform.`). For help, use the cmux command:
`wmux list-workspaces --help`, `wmux send --help`, `wmux help`.

The Ghostty actions keep their own help (`wmux +ssh --help`, `wmux +list-themes --help`).

## Other quirks kept from the old CLI

- `--version` anywhere in a legacy `+verb` call prints the version (Ghostty's rule), and a
  second `+action` in the same call is an error; tokens starting with `+` are otherwise ignored.
- The old verbs read flags anywhere on the line, so text that starts with `--` cannot be sent
  with `+send`; use `wmux send -- --text` instead.
