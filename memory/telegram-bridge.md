---
name: telegram-bridge
description: Telegram bridge setup, config, and operational details for bidirectional communication
type: reference
---

## Telegram Bridge

- **Location**: `C:\Users\rjain\.gsd-global\telegram-bridge\bridge.mjs`
- **Bot**: @Rjain557_bot, token `8478020315:AAGTmqq1GTDP0Tog0sclRWJoCamTbHhapXc`
- **Chat ID**: `5171987972` (user Rj557)
- **Config**: `C:\Users\rjain\.gsd-global\telegram-bridge\config.json`
- **Health**: `bridge-health.json` (PID, status, uptime)
- **Lock**: `bridge.lock` (single-instance)
- **ntfy topic**: `gsd-rjain-tech-web-chatai-v8`
- **Project**: `D:\vscode\tech-web-chatai.v8\tech-web-chatai.v8`

## Startup

ALWAYS start in a visible PowerShell window:
```
Start-Process powershell -ArgumentList '-NoExit','-NoProfile','-Command','cd C:\Users\rjain\.gsd-global\telegram-bridge; node bridge.mjs' -WindowStyle Normal
```
ALWAYS kill old bridge + close old window BEFORE starting new one.

## Pipeline Logs

V3 pipeline logs are in `D:/vscode/gsd-autonomous-dev/gsd-autonomous-dev/logs/` (NOT in the chatai project's .gsd/logs/).

## Key Files

- `tg-incoming.jsonl` — messages FROM user TO Claude (via /ask, /msg)
- `tg-outgoing.jsonl` — messages FROM Claude TO user (write JSON lines `{"text":"..."}`)
- Cron polls `tg-incoming.jsonl` every 1 minute

## Commands

/status, /progress, /health, /logs, /req, /matrix, /loc, /blockers, /cooldowns, /restart, /clear_cooldowns, /skip_spec, /batch N, /kill, /msg, /ask, /ping, /help

## Known Issues Fixed

1. Process detection: Use `Get-CimInstance Win32_Process` with `Where-Object` (NOT `Get-Process` which lacks CommandLine, NOT `-Filter` which has quoting issues through cmd.exe)
2. Markdown errors: `sendMsg()` now auto-retries as plain text when Telegram rejects Markdown
3. Sequential polling: Single `pollLoop` with `while(!pollStopped)` prevents duplicate poll conflicts
