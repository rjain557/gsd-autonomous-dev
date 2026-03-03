# GSD Troubleshooting Guide

## Installation Issues

### "running scripts is disabled on this system"

Fix: Run with execution policy bypass:

```powershell
powershell -ExecutionPolicy Bypass -File install-gsd-all.ps1
```

### "gsd-assess is not recognized"

The profile was not loaded. Either:
1. Restart your terminal (close and reopen)
2. Manually source: `. $PROFILE`

If that still fails, verify the profile file exists:

```powershell
Test-Path $PROFILE
cat $PROFILE | Select-String "gsd"
```

### "command claude not found" or "command codex not found"

CLI not installed or not in PATH:

```powershell
npm install -g @anthropic-ai/claude-code
npm install -g @openai/codex
```

Then restart terminal. Verify with:

```powershell
claude --version
codex --version
```

### "command gemini not found" (optional)

Gemini CLI is optional. Without it, the engine falls back to Codex for research and spec-fix phases. To install for three-model optimization:

```powershell
npm install -g @google/gemini-cli
gemini    # first run authenticates
```

### Install script fails partway through

The installer is idempotent. Re-run install-gsd-all.ps1 to pick up where it left off. It will skip already-installed components and retry failed ones.

## Runtime Issues

### "Another GSD process is running (lock file age: X min)"

A previous run left a stale lock. Clear it:

```powershell
Remove-Item ".gsd\.gsd-lock" -Force
```

Lock files auto-expire after 120 minutes. If the error persists, another GSD process may actually be running. Check with:

```powershell
Get-Process | Where-Object { $_.CommandLine -match "convergence-loop|blueprint-pipeline" }
```

### "Quota exhausted on claude" / "Sleeping 60 minutes"

Your API quota (or OAuth session limit) is exhausted. The engine sleeps and retries automatically with adaptive backoff (5 min -> 10 min -> 20 min -> 40 min -> 60 min cap). Max retry: 24 hours.

If using OAuth, close other Claude sessions to free quota. Check usage at console.anthropic.com/settings/usage.

To reduce quota consumption:
- Use -SkipResearch to skip the Gemini/Codex research phase
- Increase -ThrottleSeconds (e.g., 60 or 120) to slow down agent calls
- Reduce -MaxIterations to limit total runs
- Ensure Gemini CLI is installed (`npm install -g @google/gemini-cli`) -- Gemini uses a separate quota pool, reducing load on Claude/Codex

### "Network unavailable. Polling every 30s..."

Network connectivity lost. The engine polls until back online (max 1 hour). Check your internet connection. If you are behind a firewall, ensure claude, codex, and gemini CLIs can reach their respective APIs.

### Codex "exit code 2" with batch reduction to minimum

Codex CLI crashed. Common causes:

1. **Wrong working directory**: Codex must run from the repo root. Verify with `pwd` or `Get-Location`.
2. **Token limit exceeded**: The prompt + batch is too large. The engine auto-reduces batch size. If it fails at batch size 1, the individual item may be too complex -- break it down manually.
3. **Invalid prompt**: Check the latest log in .gsd/logs/ for the full prompt sent to Codex.
4. **Codex version incompatibility**: Run `codex --version` and verify against tested versions (0.x/1.x).

### Health score stuck / not improving (stall)

The engine auto-detects stalls after the configured threshold (default: 3 iterations). Common causes:

1. **Spec contradictions**: Run `gsd-converge -AutoResolve` to auto-fix via Gemini/Codex, or manually review .gsd/spec-consistency-report.md
2. **Circular dependencies**: Items depend on each other. Review .gsd/generation-queue/queue-current.json for dependency cycles.
3. **Batch too small**: After repeated failures, batch reduces to minimum. Try a fresh run with default settings.
4. **Fundamental architecture mismatch**: The specs may describe patterns incompatible with the existing codebase. Review the drift report at .gsd/health/drift-report.md.

### Health regression (score drops after iteration)

The engine auto-detects drops >5% and reverts to pre-iteration state. If this happens repeatedly:

1. Check .gsd/logs/ for the iteration that caused regression
2. Review what changes were made and reverted
3. The stall counter increments on regression, so the pipeline will stop after reaching the stall threshold

### JSON parsing errors / corrupt state files

The engine auto-restores from .last-good backups. If the backup is also corrupt:

```powershell
# Reset health state
Remove-Item ".gsd\health\health-current.json" -Force
# Re-run to regenerate
gsd-converge -SkipInit
```

### Agent boundary violation detected

An agent wrote to files outside its allowed scope. The engine auto-reverts these changes. If it keeps happening:

1. Check .gsd/logs/errors.jsonl for boundary_violation entries
2. The prompt may be ambiguous -- review the agent-handoff/current-assignment.md
3. Ensure the .gsd/config/ has correct agent boundary definitions

## Notification Issues

### Not receiving ntfy notifications

1. **Check the topic name**: It prints at pipeline startup as `ntfy topic (auto): gsd-rjain-projectname`
2. **Verify subscription**: In the ntfy app, confirm you subscribed to the exact topic name (case-sensitive)
3. **Test manually**: Open `https://ntfy.sh/your-topic-name` in a browser, then send a test:

```powershell
Invoke-RestMethod -Uri "https://ntfy.sh/gsd-rjain-myproject" -Method Post -Body "test notification"
```

4. **Firewall**: Ensure outbound HTTPS to ntfy.sh is not blocked

### Notifications going to wrong topic

If you renamed a repo or switched users, the auto-detected topic changes. Check the current topic:

```powershell
# See what topic would be generated
$user = $env:USERNAME.ToLower()
$repo = (git config --get remote.origin.url) -replace '\.git$', '' -replace '.*/|.*:', '' | Split-Path -Leaf
Write-Host "gsd-$user-$($repo.ToLower())"
```

To force a specific topic, either:
- Use `-NtfyTopic "fixed-topic"` on every run
- Set ntfy_topic in %USERPROFILE%\.gsd-global\config\global-config.json to your preferred topic string

### Notifications disabled / no ntfy output at startup

If you see no "ntfy topic" line at startup, notifications are not initialized. This happens when:
1. The resilience.ps1 module was not patched with notification functions (re-run install-gsd-all.ps1)
2. The global-config.json is missing or has invalid JSON

## Spec Conflict Issues

### "BLOCKED: Critical spec conflicts detected"

The spec consistency check found contradictions that would cause build failures. Options:

1. **Auto-resolve**: Re-run with `-AutoResolve` flag to let Gemini fix them automatically
2. **Manual fix**: Review .gsd/spec-consistency-report.md, fix the specs manually, then re-run
3. **Skip check**: Use `-SkipSpecCheck` to bypass (not recommended, may cause iteration failures)

### Auto-resolve fails to fix conflicts

If -AutoResolve cannot resolve after 2 attempts:
1. Review .gsd/spec-conflicts/resolution-summary.md for what was attempted
2. The conflict may require human judgment (e.g., two equally valid business rules)
3. Fix the underlying spec files manually and re-run

## Gemini Issues

### Gemini CLI not responding / authentication failure

```powershell
# Re-authenticate
gemini    # interactive first-run auth
# Verify
"Say READY" | gemini --sandbox 2>&1
```

If Gemini is down or unresponsive, the engine automatically falls back to Codex for research and spec-fix phases. No manual intervention required.

### Research output quality differs between Gemini and Codex

Gemini and Codex may produce different research findings. If research quality degrades after switching to Gemini:

```powershell
gsd-converge -SkipResearch    # Skip research entirely (fastest)
```

Or uninstall Gemini CLI to force Codex fallback:

```powershell
npm uninstall -g @google/gemini-cli
```

## Throttling / Performance Issues

### Pipeline running too slowly

Reduce throttle delay:

```powershell
gsd-converge -ThrottleSeconds 10    # Faster but higher quota risk
gsd-converge -ThrottleSeconds 0     # No delay (maximum speed, may hit quota)
```

### Hitting quota limits frequently

Increase throttle delay and reduce scope:

```powershell
gsd-converge -ThrottleSeconds 120 -SkipResearch -MaxIterations 5
```

### Disk space warnings

The engine auto-cleans when space is low, but if it persists:

```powershell
# Manual cleanup
Remove-Item -Recurse -Force node_modules\.cache 2>$null
Remove-Item -Recurse -Force bin, obj 2>$null
Remove-Item ".gsd\logs\*.log" -Force  # Clear old iteration logs
```

## Common Workflows

### Starting fresh on a project

```powershell
cd C:\path\to\your\repo
gsd-init                    # Initialize .gsd/ folder
gsd-assess                  # Run full assessment
gsd-converge                # Start convergence loop
```

### Resuming after a crash

Just re-run the same command. The checkpoint system auto-resumes from the last successful phase:

```powershell
gsd-converge                # Automatically resumes from checkpoint
```

### Monitoring from your phone

```powershell
gsd-converge                # Note the "ntfy topic (auto): ..." line
# Subscribe to that topic in the ntfy app on your phone
# OR use gsd-remote for interactive QR-code based monitoring:
gsd-remote
```

### Running multiple projects overnight

Open separate terminals for each project:

```powershell
# Terminal 1
cd C:\repos\patient-portal
gsd-converge -ThrottleSeconds 60

# Terminal 2
cd C:\repos\billing-api
gsd-converge -ThrottleSeconds 60

# Terminal 3
cd C:\repos\admin-dashboard
gsd-blueprint -ThrottleSeconds 60
```

Each project auto-subscribes to its own ntfy topic. Subscribe to all three in the ntfy app to monitor them simultaneously.
