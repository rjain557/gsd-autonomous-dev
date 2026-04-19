#!/usr/bin/env bash
# reindex.sh — PostToolUse hook (Bash tool)
# Runs gitnexus analyze after git commit or git merge to keep index fresh.

INPUT=$(cat)

# Extract the bash command that was run
CMD=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    inp = d.get('tool_input', {})
    print(inp.get('command', ''))
except:
    print('')
" 2>/dev/null)

# Only reindex after commit or merge
if echo "$CMD" | grep -qE "git (commit|merge)"; then
    cd /c/VSCode/gsd-autonomous-dev/gsd-autonomous-dev 2>/dev/null || exit 0

    # Check if embeddings exist (preserve them if so)
    EMBEDDINGS=$(python3 -c "
import json
try:
    with open('.gitnexus/meta.json') as f:
        d = json.load(f)
    print(d.get('stats', {}).get('embeddings', 0))
except:
    print(0)
" 2>/dev/null || echo "0")

    if [ "$EMBEDDINGS" -gt 0 ]; then
        npx gitnexus analyze --embeddings 2>/dev/null &
    else
        npx gitnexus analyze 2>/dev/null &
    fi
fi
