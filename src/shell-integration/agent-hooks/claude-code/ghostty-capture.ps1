# Ghostty session-capture hook for Claude Code (native Windows / pwsh).
#
# Registered as the `SessionStart` hook command in ~/.claude/settings.json
# (see settings.hooks.json). Claude Code pipes the SessionStart event to
# this script's stdin as a single JSON object, e.g.:
#
#   {"session_id":"abc123","transcript_path":"...","cwd":"C:\\proj",
#    "hook_event_name":"SessionStart","source":"startup"}
#
# We read `session_id` and forward it to the Ghostty instance that owns
# this shell (resolved from $env:GHOSTTY_PID inside +session capture).
#
# The hook is best-effort and MUST be non-fatal to the agent: any failure
# (Ghostty not running, no pipe, malformed payload) exits 0 silently so it
# never blocks the session from starting. Output on the SessionStart hook
# is not injected as context; we deliberately emit nothing on stdout.

$ErrorActionPreference = 'SilentlyContinue'

try {
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { exit 0 }

    $payload = $raw | ConvertFrom-Json
    $sid = $payload.session_id
    if (-not $sid) { exit 0 }

    # Prefer the Ghostty binary directory Ghostty exports into the shell;
    # fall back to PATH.
    $ghostty = 'ghostty'
    if ($env:GHOSTTY_BIN_DIR) {
        $cand = Join-Path $env:GHOSTTY_BIN_DIR 'ghostty.exe'
        if (Test-Path $cand) { $ghostty = $cand }
    }

    # Name our own pane explicitly via GHOSTTY_SURFACE_ID (a hex id) when
    # Ghostty exported it, removing the active-pane race for an agent that
    # starts in a non-focused pane; fall back to active-pane resolution.
    if ($env:GHOSTTY_SURFACE_ID) {
        & $ghostty +session capture --agent claude_code --session "$sid" --surface "$env:GHOSTTY_SURFACE_ID" *> $null
    } else {
        & $ghostty +session capture --agent claude_code --session "$sid" *> $null
    }
} catch {
    # Swallow everything: a capture failure must never break the agent.
}

exit 0
