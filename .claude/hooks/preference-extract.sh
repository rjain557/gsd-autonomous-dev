#!/usr/bin/env bash
# preference-extract.sh — Stop hook
# Scans session log for preference-shaped statements and offers to save them.
# Preferences are saved to claude-memory/preferences.md after explicit confirmation.
# NOTE: This hook only signals; Claude must handle the actual save via /consolidate or direct write.

VAULT="${GSD_VAULT_MEMORY:-"/c/Users/rjain/OneDrive - Technijian, Inc/Documents/obsidian/gsd-autonomous-dev/gsd-autonomous-dev/claude-memory"}"
LOG="$VAULT/.retrieval-log.jsonl"

INPUT=$(cat)
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Log preference-check event
echo "{\"ts\":\"$TIMESTAMP\",\"event\":\"preference_check\"}" >> "$LOG" 2>/dev/null

# Signal Claude to check for preference-shaped statements in the session
MSG="If the user expressed any preferences during this session (\"I prefer X\", \"always do Y\", \"never do Z\"), offer to save them to claude-memory/preferences.md. Ask before writing — preferences should feel intentional."
ESCAPED=$(printf '%s' "$MSG" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null || echo '"Check if any preferences were expressed and offer to save them."')
printf '{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":%s}}\n' "$ESCAPED"
