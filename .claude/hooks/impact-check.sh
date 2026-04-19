#!/usr/bin/env bash
# impact-check.sh — PreToolUse hook (Edit/Write)
# Warns when editing agent, orchestrator, or harness files.
# Full blast-radius analysis requires running gitnexus_impact via MCP.

INPUT=$(cat)

FILE_PATH=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    inp = d.get('tool_input', {})
    print(inp.get('file_path', ''))
except:
    print('')
" 2>/dev/null)

[ -z "$FILE_PATH" ] && exit 0

# Classify risk level based on file path
RISK="LOW"
REASON=""

if echo "$FILE_PATH" | grep -qiE "orchestrator|harness"; then
    RISK="CRITICAL"
    REASON="Orchestrator/harness changes affect ALL pipeline routing decisions."
elif echo "$FILE_PATH" | grep -qiE "src/agents/"; then
    RISK="HIGH"
    REASON="Agent changes may break pipeline stage contracts. Check callers with gitnexus_impact."
elif echo "$FILE_PATH" | grep -qiE "src/(index|cli)"; then
    RISK="HIGH"
    REASON="CLI entry point — all commands are affected. Check gitnexus_impact before editing."
elif echo "$FILE_PATH" | grep -qiE "\.(ts|js)$" && echo "$FILE_PATH" | grep -qiE "src/"; then
    RISK="MEDIUM"
    REASON="TypeScript source change. Run gitnexus_impact to check upstream callers."
fi

if [ "$RISK" = "CRITICAL" ] || [ "$RISK" = "HIGH" ]; then
    MSG="[$RISK] $REASON Run: gitnexus_impact({target: \"<symbol>\", direction: \"upstream\"}) before editing."
    ESCAPED=$(printf '%s' "$MSG" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null || echo '"Run gitnexus_impact before editing this file."')
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":%s}}\n' "$ESCAPED"
fi
