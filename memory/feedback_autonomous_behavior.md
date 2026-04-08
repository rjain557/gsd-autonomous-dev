---
name: feedback_autonomous_behavior
description: CRITICAL - Be truly autonomous. Stop waiting for user to tell you what to do. Detect, diagnose, fix, restart on your own.
type: feedback
---

# Autonomous Behavior - CRITICAL Feedback (2026-03-11)

## Core Problem
User has had to repeatedly tell me what to do instead of me figuring it out autonomously. This defeats the entire purpose of the GSD autonomous dev system.

## Autonomous Pipeline Monitoring Rules

### Detection (every cron tick)
1. Read logs for patterns, not just status
2. Compare issue counts across iterations — if same or worse, it's a disease
3. If health delta = 0 for 2 iterations, it's a stall — ACT immediately
4. If same file gets destroyed/restored 2x, add it to blocked list AND restart
5. If validator crashes, read the error, fix the code, restart
6. If fixer never runs, investigate why, fix it

### Action (don't wait for user)
1. Stop the pipeline when it's clearly not working
2. Fix the root cause in the code (orchestrator, validator, fixer)
3. Fix failing requirements directly when pipeline can't
4. Update health matrix after direct fixes
5. Restart pipeline only after fixes are verified (build clean)
6. Kill old processes BEFORE starting new ones
7. Write PIDs and status to memory immediately

### Pattern Recognition
1. Track issue counts per requirement across iterations
2. If a requirement fails 3x with same issues → fix it directly, don't wait for pipeline
3. If build errors recur after fix → the write guard isn't blocking the file, add to blocked list
4. If logs show [WRITE] where [BLOCKED] expected → write guard bypass, investigate
5. If CPU flat for 5+ minutes → process might be hung, check and restart

### What NOT to do
1. Don't passively report "Status: Healthy" for hours
2. Don't make code changes without restarting to activate them
3. Don't restore the same file 5 times without fixing the root cause
4. Don't wait for user to tell you something is broken when logs clearly show it
5. Don't open new PowerShell windows without closing old ones
6. Don't overwrite logs — use timestamped log files
