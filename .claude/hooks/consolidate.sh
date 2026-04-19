#!/usr/bin/env bash
# consolidate.sh — Stop hook
# Signals that the session ended. Claude should decide if the exchange
# produced durable knowledge and run /consolidate if so.
# This hook logs session end and emits a reminder if the session was substantive.

VAULT="${GSD_VAULT_MEMORY:-"/c/Users/rjain/OneDrive - Technijian, Inc/Documents/obsidian/gsd-autonomous-dev/gsd-autonomous-dev/claude-memory"}"
CHANGELOG="$VAULT/CHANGELOG.md"
LOG="$VAULT/.retrieval-log.jsonl"

INPUT=$(cat)
STOP_REASON=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('stop_reason', 'unknown'))
except:
    print('unknown')
" 2>/dev/null)

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "{\"ts\":\"$TIMESTAMP\",\"event\":\"session_end\",\"stop_reason\":\"$STOP_REASON\"}" >> "$LOG" 2>/dev/null

# Check retrieval log for activity this session (last 2 hours)
RECENT_ACTIVITY=$(python3 -c "
import json, datetime
try:
    cutoff = (datetime.datetime.utcnow() - datetime.timedelta(hours=2)).isoformat() + 'Z'
    count = 0
    with open('$LOG') as f:
        for line in f:
            try:
                e = json.loads(line)
                if e.get('ts','') > cutoff and e.get('event') == 'retrieve':
                    count += 1
            except:
                pass
    print(count)
except:
    print(0)
" 2>/dev/null || echo "0")

# If there was substantive vault activity, suggest consolidation
if [ "$RECENT_ACTIVITY" -gt 0 ] 2>/dev/null; then
    MSG="Vault retrieved $RECENT_ACTIVITY topic(s) this session. Run /consolidate to save durable knowledge from this exchange."
    ESCAPED=$(printf '%s' "$MSG" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null || echo '"Run /consolidate to save session knowledge."')
    printf '{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":%s}}\n' "$ESCAPED"
fi
