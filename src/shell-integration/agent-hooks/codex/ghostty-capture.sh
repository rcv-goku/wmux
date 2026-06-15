#!/usr/bin/env bash
# Ghostty session-capture hook for OpenAI Codex CLI (WSL / Git-Bash).
#
# Registered as the Codex `SessionStart` hook command in
# $CODEX_HOME/config.toml (use this .sh path for Codex running under a
# POSIX shell). Codex pipes the SessionStart event JSON to stdin with a
# UUID `session_id`:
#
#   {"session_id":"550e8400-e29b-41d4-a716-446655440000","cwd":"/proj",
#    "hook_event_name":"SessionStart","model":"...","source":"startup"}
#
# We extract `session_id` and forward it to the Ghostty instance that owns
# this shell (resolved from $GHOSTTY_PID inside +session capture) so the
# workspace can relaunch with `codex resume <session_id>`.
#
# Best-effort and strictly non-fatal: any failure exits 0. Emits nothing.
set +e

payload="$(cat)"
[ -z "$payload" ] && exit 0

if command -v jq >/dev/null 2>&1; then
    sid="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)"
else
    sid="$(printf '%s' "$payload" \
        | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -n1 \
        | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/')"
fi
[ -z "$sid" ] && exit 0

ghostty="ghostty"
if [ -n "$GHOSTTY_BIN_DIR" ] && [ -x "$GHOSTTY_BIN_DIR/ghostty" ]; then
    ghostty="$GHOSTTY_BIN_DIR/ghostty"
fi

# Name our own pane explicitly via GHOSTTY_SURFACE_ID (a hex id) when
# Ghostty exported it, removing the active-pane race for an agent that
# starts in a non-focused pane; fall back to active-pane resolution.
if [ -n "$GHOSTTY_SURFACE_ID" ]; then
    "$ghostty" +session capture --agent codex --session "$sid" --surface "$GHOSTTY_SURFACE_ID" >/dev/null 2>&1
else
    "$ghostty" +session capture --agent codex --session "$sid" >/dev/null 2>&1
fi
exit 0
