# Agent session-resume hooks

These are the per-agent hook artifacts that let Ghostty (Windows) capture
each agent's **native session id** the moment a session starts or resumes,
so a workspace can later be relaunched with the agent's own resume command
(`claude --resume <id>`, `codex resume <id>`, ...).

They are *templates/scripts only* — pure data + tiny shims that call back
into the running Ghostty over its existing per-process IPC pipe
(`ghostty-ipc-<pid>`). None of them require the orchestration Zig wiring to
exist yet; they are committed ahead of it so `ghostty +hooks setup` (a
future verb) can copy them into place.

## Capture mechanism

Every agent that supports lifecycle hooks gets a hook that runs a short
command at **session start / resume**. That command reads the agent's hook
payload (which contains the session id) and forwards it to Ghostty:

```
ghostty +session capture --agent <kind> --session <id>
```

`+session capture` (a planned IPC verb, see
`agent-orchestration-design.md`) resolves the target instance from
`GHOSTTY_PID` — already exported into every shell Ghostty spawns
(`src/termio/Exec.zig`) — and records the mapping in the in-process
`agent_session.Store` keyed by the calling surface. Because the hook runs
*inside* the agent's process tree, it inherits `GHOSTTY_PID`, so the
callback lands on the right instance with no enumeration.

No hook reaches the network and none needs elevated permissions; they only
spawn the local `ghostty` already on `PATH` (also guaranteed by
`GHOSTTY_BIN_DIR` in `Exec.zig`).

## Per-agent confidence

| Agent        | Hook event                  | Session-id source           | Confidence |
|--------------|-----------------------------|-----------------------------|------------|
| Claude Code  | `SessionStart` (settings.json) | stdin JSON `session_id`     | High — documented |
| Codex        | `SessionStart` (config.toml)   | stdin JSON `session_id`     | High — documented |
| Gemini CLI   | no public hook yet          | `gemini --resume` / picker  | Medium — resume documented, capture is best-effort |
| OpenCode     | no public hook yet          | `~/.local/share/opencode`   | Medium — storage path may change |
| Aider        | none                        | n/a (resumes by cwd)        | Low — no per-id capture; `--restore-chat-history` |

See the design doc for the honest per-agent breakdown. Files here cover the
two **documented** cases (Claude Code, Codex). The others are listed as
TODO stubs so the layout is ready, not faked.

## Files

- `claude-code/settings.hooks.json` — JSON fragment to merge into
  `~/.claude/settings.json` (`hooks.SessionStart`).
- `claude-code/ghostty-capture.sh` / `.ps1` — the hook command: reads the
  `SessionStart` JSON on stdin, extracts `session_id`, calls
  `ghostty +session capture`.
- `codex/config.hooks.toml` — TOML fragment to merge into
  `$CODEX_HOME/config.toml` (`[[hooks.SessionStart]]`).
- `codex/ghostty-capture.sh` / `.ps1` — same shim for Codex's stdin JSON.

The `.sh` variants are for WSL/Git-Bash agents; the `.ps1` variants for
native-Windows agents. `+hooks setup` picks the right one per the agent's
runtime.
