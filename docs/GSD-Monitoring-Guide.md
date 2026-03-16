# GSD Monitoring Guide

## Overview

The GSD V3 pipeline supports multiple monitoring channels for real-time visibility into pipeline progress, health, and cost. Monitoring can be configured for passive observation (push notifications) or active intervention (command listeners, dual-CLI pattern).

Available monitoring channels:

1. **ntfy.sh** -- Push notifications to phone/desktop (free, no account needed)
2. **Telegram** -- Bot notifications via bridge
3. **Claude Code CLI** -- Active monitoring with two cooperating instances

## ntfy.sh Push Notifications

### How It Works

The pipeline automatically publishes notifications to ntfy.sh on key events. The topic is auto-generated from your username and repository name.

### Setup

1. Install the ntfy app on your phone (free, available on iOS App Store and Google Play)
2. Run any V3 pipeline once and note the topic printed at startup:
   ```
   Notifications: ntfy.sh topic = gsd-rjain-tech-web-chatai
   Subscribe: https://ntfy.sh/gsd-rjain-tech-web-chatai
   ```
3. Subscribe to that topic in the ntfy app
4. Repeat for each project you monitor

### Notification Events

| Event | Tags | Priority | Description |
|-------|------|----------|-------------|
| iteration_complete | chart_with_upwards_trend / warning | default | Health %, delta, elapsed time, cost |
| converged | tada | high | All requirements satisfied |
| stalled | warning | default | Health delta = 0 for N iterations |
| budget_threshold | warning | default | 80% of budget consumed |
| error | x | high | Pipeline error or crash |
| cache_invalidated | recycle | default | Cache prefix changed, re-warming |
| opus_escalation | sos | high | Model escalated to Opus for stuck requirement |
| batch_completed | white_check_mark | default | Batch API batch finished |
| speculative_waste | warning | low | Speculative execution wasted tokens |

### Remote Commands

You can send commands back to the pipeline by publishing messages to the same ntfy topic. The pipeline polls for incoming commands every 15 seconds.

| Command | Response |
|---------|----------|
| `progress` | Full status report: health %, iteration, phase, items breakdown, cost |
| `cost` or `costs` or `token` or `tokens` | Detailed cost report: total, by phase, API call counts |
| `whatsapp` | Kill and restart the WhatsApp bridge process |

Send a command from the ntfy app by publishing a message to the topic, or via curl:

```bash
curl -d "progress" https://ntfy.sh/gsd-rjain-tech-web-chatai
```

### Heartbeat Monitor

The pipeline runs a background heartbeat job that sends a status update every 10 minutes. If you stop receiving heartbeats, the pipeline has likely crashed.

Heartbeat messages include: repository name, current iteration, health %, active phase, timestamp, and cost.

## Telegram Bridge

### Setup

1. Create a Telegram bot via @BotFather and obtain the bot token
2. Get your chat ID by messaging the bot and checking the updates API
3. Start the bridge:

```bash
node telegram-bridge.js --token $TELEGRAM_BOT_TOKEN --chat-id $CHAT_ID
```

### Message Format

Telegram notifications include:
- Iteration number
- Health percentage and delta
- Current phase
- Cost summary
- Elapsed time

### Configuration

Store Telegram configuration in environment variables:

```powershell
[System.Environment]::SetEnvironmentVariable("TELEGRAM_BOT_TOKEN", "your-token", "User")
[System.Environment]::SetEnvironmentVariable("TELEGRAM_CHAT_ID", "your-chat-id", "User")
```

## Dual Claude Code CLI Monitoring Pattern

For maximum pipeline effectiveness, run two Claude Code CLI instances in separate VS Code terminals. This pattern provides active monitoring, proactive error fixing, and notification routing.

### Terminal 1: Pipeline Monitor

This instance starts the pipeline, watches its progress, and proactively fixes issues.

**Role**: Pipeline babysitter and proactive fixer

**Responsibilities**:

- Start the pipeline in a visible PowerShell window (always `-NoExit`, never `-WindowStyle Hidden`)
- Create a 1-minute cron monitoring cycle that checks:
  - Pipeline process (PID) is alive
  - Tail log file for errors or warnings
  - Spec drift every tick
  - Full health check every 10 ticks
  - Proactive build error identification and fixing
  - Memory file updates every 10 ticks
- Fix stuck requirements directly using the larger Claude Code context window
- Launch background agents for batch fixes when multiple requirements need similar changes
- Update the traceability matrix with fix results

**Key Commands**:

```
"Start pipeline v3 for [project] and monitor"
"Fix all partial requirements"
"Check spec drift"
"How is progress"
"Audit skipped files"
"Promote all partial reqs to satisfied"
"Run bulk fixes for [interface]"
```

**Window Management**: Always kill the old pipeline process before starting a new one. Never leave orphaned PowerShell windows. When killing a pipeline, also close its PowerShell window.

### Terminal 2: Notification Monitor

This instance monitors external notification channels and handles escalations.

**Role**: Notification router and escalation handler

**Responsibilities**:

- Watch ntfy.sh for pipeline notifications
- Watch Telegram for user commands
- Route alerts appropriately:
  - ntfy gets short summary only
  - Telegram/WhatsApp gets full message details first
- Handle cost alerts: pause pipeline if over budget
- Handle stall alerts: diagnose root cause and recommend action
- Coordinate with Terminal 1 via shared memory files

**Key Commands**:

```
"Monitor notifications for [project]"
"Check ntfy for any alerts"
"Send progress update to Telegram"
"Escalate: pipeline stalled at 89%"
"Cost report for current run"
```

### How the Two Instances Coordinate

Both instances share state through memory files in the Claude Code project memory directory:

```
~/.claude/projects/[project]/memory/
  active-tasks.md      # Current PIDs, cron IDs, progress metrics
  session-state.md     # Crash recovery state, active processes
  cross-session.md     # Message board between instances
  MEMORY.md            # Long-term project knowledge
  patterns.md          # Cross-session pattern analysis
```

**Coordination flow**:
1. Pipeline monitor writes health updates, iteration progress, and error reports
2. Notification monitor reads health data and routes to user via appropriate channels
3. Cross-session.md serves as a message board for urgent coordination
4. Both instances read MEMORY.md for project context and patterns

### Setup Steps

1. Open Terminal 1 in VS Code and start Claude Code
2. Tell it: "Read memory, start pipeline for [project], create 1-min monitor"
3. Open Terminal 2 in VS Code and start Claude Code
4. Tell it: "Monitor notifications for [project], watch ntfy and Telegram"
5. Both instances will automatically share memory through the project memory directory

### Recovery After VS Code Restart

VS Code updates will kill Claude Code terminal sessions. On restart:

1. Both instances should read `MEMORY.md`, `active-tasks.md`, and `session-state.md`
2. Check if the pipeline process is still running (PID from session-state.md)
3. If the pipeline crashed, resume with `-StartIteration N` using the checkpoint
4. Re-establish the monitoring cron cycle

## Alert Severity Levels

| Level | Source | Action |
|-------|--------|--------|
| Info | Iteration complete, heartbeat | Log only |
| Warning | Health delta = 0, cost alert at 80%, moderate spec drift | Notify user via ntfy/Telegram |
| High | Pipeline stalled (3+ zero-delta), health regression, budget exceeded | Notify + diagnose root cause |
| Critical | Pipeline crashed, critical spec drift (>20%), process died | Notify + auto-fix if possible, escalate to user |

## Memory Management for Monitoring

Effective monitoring requires consistent memory updates across sessions.

### File Update Schedule

| File | Updated By | Frequency | Content |
|------|-----------|-----------|---------|
| active-tasks.md | Pipeline monitor | Every 10 cron ticks | Running PIDs, cron IDs, current progress |
| session-state.md | Pipeline monitor | On pipeline start/stop | Process state for crash recovery |
| MEMORY.md | Either instance | Per session | Long-term project knowledge, health milestones |
| cross-session.md | Either instance | As needed | Urgent inter-CLI messages, coordination |
| patterns.md | Pipeline monitor | Per session | Recurring failure patterns, model reliability |

### Memory Best Practices

- Always read memory files at session start to recover context
- Keep active-tasks.md current so the notification monitor has accurate data
- Use cross-session.md for time-sensitive coordination (one instance can flag an issue for the other)
- Update MEMORY.md with significant milestones (health thresholds crossed, runs completed, total cost)
- Never close a Claude Code session unless explicitly asked -- cron monitoring dies when the session ends

## Log File Monitoring

### Real-Time Log Tailing

```powershell
# Tail the live log from another terminal
Get-Content D:\vscode\gsd-autonomous-dev\gsd-autonomous-dev\v3-pipeline-live.log -Wait

# Or tail a specific run's log
Get-Content D:\vscode\gsd-autonomous-dev\gsd-autonomous-dev\logs\v3-pipeline-2026-03-15_103243.log -Wait
```

### Key Log Patterns to Watch

| Pattern | Meaning | Action |
|---------|---------|--------|
| `[ANTI-PLATEAU]` | Zero-delta iterations detected | Check stuck requirements |
| `[COST-ALERT]` | Per-requirement cost threshold hit | Review expensive requirements |
| `[REGRESSION]` | Previously satisfied requirement regressed | Investigate code changes |
| `[BUDGET]` | Budget threshold or exhaustion | Review costs, adjust budget |
| `[BLOCKED]` | Spec gate blocked pipeline | Fix specification issues |
| `[WARN]` | Non-critical issue | Monitor, may need attention |
| `[XX]` | Critical error | Immediate investigation needed |

## Health Score Tracking

Health is calculated as:

```
score = (satisfied * 1.0 + partial * 0.5) / total * 100
```

Health history is stored as JSONL at `.gsd/health/health-history.jsonl`, with one entry per iteration:

```json
{"iteration": 15, "score": 72.5, "delta": 2.3, "timestamp": "2026-03-15T10:00:00Z"}
```

Current health snapshot is at `.gsd/health/health-current.json`.
