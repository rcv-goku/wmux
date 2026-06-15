#!/usr/bin/env bash
# Ghostty session-capture hook for Claude Code (WSL / Git-Bash).
#
# Registered as the `SessionStart` hook command in ~/.claude/settings.json
# (use this .sh path instead of the .ps1 for agents running under a POSIX
# shell). Claude Code pipes the SessionStart event JSON to stdin:
#
#   {"session_id":"abc123","transcript_path":"...","cwd":"/proj",
#    "hook_event_name":"SessionStart","source":"startup"}
#
# We extract `session_id` and forward it to the Ghostty instance that owns
# this shell (resolved from $GHOSTTY_PID inside +session capture).
#
# Best-effort and strictly non-fatal: any failure exits 0 so it can never
# block the agent's session from starting. Emits nothing on stdout (the
# SessionStart hook does not inject stdout as context, but we keep it clean
# regardless).
set +e

payload="$(cat)"
[ -z "$payload" ] && exit 0

# Extract session_id. Prefer jq when present; fall back to a tolerant grep.
if command -v jq >/dev/null 2>&1; then
    sid="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)"
else
    sid="$(printf '%s' "$payload" \
        | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -n1 \
        | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/')"
fi
[ -z "$sid" ] && exit 0

# Resolve the ghostty binary: GHOSTTY_BIN_DIR is exported into the shell by
# Ghostty; fall back to PATH.
ghostty="ghostty"
if [ -n "$GHOSTTY_BIN_DIR" ] && [ -x "$GHOSTTY_BIN_DIR/ghostty" ]; then
    ghostty="$GHOSTTY_BIN_DIR/ghostty"
fi

# Name our own pane explicitly via GHOSTTY_SURFACE_ID (a hex id) when
# Ghostty exported it, removing the active-pane race for an agent that
# starts in a non-focused pane; fall back to active-pane resolution.
if [ -n "$GHOSTTY_SURFACE_ID" ]; then
    "$ghostty" +session capture --agent claude_code --session "$sid" --surface "$GHOSTTY_SURFACE_ID" >/dev/null 2>&1
else
    "$ghostty" +session capture --agent claude_code --session "$sid" >/dev/null 2>&1
fi
exit 0
