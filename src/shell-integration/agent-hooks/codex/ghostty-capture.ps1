# Ghostty session-capture hook for OpenAI Codex CLI (native Windows / pwsh).
#
# Registered as the Codex `SessionStart` hook command in
# $CODEX_HOME/config.toml (see config.hooks.toml). Codex pipes the
# SessionStart event to stdin as one JSON object that includes a UUID
# `session_id`:
#
#   {"session_id":"550e8400-e29b-41d4-a716-446655440000","cwd":"C:\\proj",
#    "hook_event_name":"SessionStart","model":"...","source":"startup"}
#
# We read `session_id` and forward it to the Ghostty instance that owns
# this shell (resolved from $env:GHOSTTY_PID inside +session capture), so
# the workspace can later relaunch with `codex resume <session_id>`.
#
# Best-effort and strictly non-fatal: any failure exits 0 silently so the
# Codex session is never blocked. Emits nothing on stdout.

$ErrorActionPreference = 'SilentlyContinue'

try {
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { exit 0 }

    $payload = $raw | ConvertFrom-Json
    $sid = $payload.session_id
    if (-not $sid) { exit 0 }

    $ghostty = 'ghostty'
    if ($env:GHOSTTY_BIN_DIR) {
        $cand = Join-Path $env:GHOSTTY_BIN_DIR 'ghostty.exe'
        if (Test-Path $cand) { $ghostty = $cand }
    }

    # Name our own pane explicitly via GHOSTTY_SURFACE_ID (a hex id) when
    # Ghostty exported it, removing the active-pane race for an agent that
    # starts in a non-focused pane; fall back to active-pane resolution.
    if ($env:GHOSTTY_SURFACE_ID) {
        & $ghostty +session capture --agent codex --session "$sid" --surface "$env:GHOSTTY_SURFACE_ID" *> $null
    } else {
        & $ghostty +session capture --agent codex --session "$sid" *> $null
    }
} catch {
    # Swallow everything: capture must never break the agent.
}

exit 0
