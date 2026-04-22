#!/usr/bin/env bash
# retrieve.sh — UserPromptSubmit hook
# Loads matching vault topics + always loads preferences.md into context.

VAULT="${GSD_VAULT_MEMORY:-"/c/Users/rjain/OneDrive - Technijian, Inc/Documents/obsidian/gsd-autonomous-dev/gsd-autonomous-dev/claude-memory"}"
PREFS="$VAULT/preferences.md"
LOG="$VAULT/.retrieval-log.jsonl"
TOPICS="$VAULT/topics"

INPUT=$(cat)
PROMPT=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('prompt', ''))
except:
    print('')
" 2>/dev/null)

CONTEXT=""

# Always load preferences
if [ -f "$PREFS" ]; then
    PREF_CONTENT=$(cat "$PREFS")
    CONTEXT="### User Preferences\n${PREF_CONTENT}\n\n"
fi

# Match topic files by name/alias keywords against prompt
if [ -d "$TOPICS" ] && [ -n "$PROMPT" ]; then
    for topic_file in "$TOPICS"/*.md; do
        [ -f "$topic_file" ] || continue
        TOPIC_NAME=$(basename "$topic_file" .md)
        TOPIC_WORDS=$(echo "$TOPIC_NAME" | tr '-' ' ')

        # Check topic name and aliases header against prompt
        ALIASES=$(grep -m1 "^aliases:" "$topic_file" 2>/dev/null | sed 's/aliases: \[//;s/\]//' | tr ',' '\n' | tr -d '[]"' | xargs)
        MATCH=0
        for kw in $TOPIC_WORDS $ALIASES; do
            [ ${#kw} -lt 4 ] && continue
            if echo "$PROMPT" | grep -qi "$kw"; then
                MATCH=1
                break
            fi
        done

        if [ "$MATCH" -eq 1 ]; then
            TOPIC_CONTENT=$(cat "$topic_file")
            CONTEXT="${CONTEXT}### Vault Topic: ${TOPIC_NAME}\n${TOPIC_CONTENT}\n\n"
            TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            echo "{\"ts\":\"$TIMESTAMP\",\"event\":\"retrieve\",\"topic\":\"$TOPIC_NAME\",\"query\":\"${PROMPT:0:100}\"}" >> "$LOG" 2>/dev/null
        fi
    done
fi

# Emit context if anything matched
if [ -n "$CONTEXT" ]; then
    ESCAPED=$(printf '%s' "$CONTEXT" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null || echo '""')
    printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":%s}}\n' "$ESCAPED"
fi
