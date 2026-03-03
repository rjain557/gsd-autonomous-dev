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

## API Key Issues

### API keys not being used by agents

If you set API keys but agents still use interactive auth:

1. **Restart your terminal**: API keys set via `setup-gsd-api-keys.ps1` are stored as User-level environment variables. New terminal sessions pick them up automatically, but existing sessions need a restart.
2. **Verify keys are set**: Run `.\scripts\setup-gsd-api-keys.ps1 -Show` to see current status.
3. **Check variable names**: The exact names must be ANTHROPIC_API_KEY, OPENAI_API_KEY, and GOOGLE_API_KEY (all uppercase with underscores).

```powershell
# Quick verify in current session
$env:ANTHROPIC_API_KEY
$env:OPENAI_API_KEY
$env:GOOGLE_API_KEY
```

### "Expected key to start with 'sk-ant-'" warning

The prefix validation is advisory only. If you are certain the key is correct, the script will set it anyway. Key prefix formats may change when providers update their API key format.

### Updating or rotating API keys

Re-run the setup script to update keys. It shows current values (masked) and lets you enter new ones:

```powershell
.\scripts\setup-gsd-api-keys.ps1
```

Or pass keys directly for non-interactive update:

```powershell
.\scripts\setup-gsd-api-keys.ps1 -AnthropicKey "sk-ant-new-key..."
```

### Removing API keys

To remove all API key environment variables and revert to interactive auth:

```powershell
.\scripts\setup-gsd-api-keys.ps1 -Clear
```

Restart your terminal for the removal to take effect in new processes.

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

### No heartbeat notifications during long runs

The engine uses two heartbeat mechanisms:
- **Background heartbeat job**: An independent PowerShell background job sends notifications every 10 minutes, even while an agent call is blocking the main thread. This is the primary heartbeat source.
- **Phase-transition heartbeat**: `Send-HeartbeatIfDue` fires between agent phases as a secondary check.

If you're not seeing heartbeats:

1. **Check elapsed time**: Heartbeats only fire after 10 minutes since the pipeline started. If iterations complete in under 10 minutes, you'll see iteration-complete notifications instead.
2. **Verify installation**: Re-run `install-gsd-all.ps1` to ensure `Start-BackgroundHeartbeat` is deployed.
3. **Check subscription**: Heartbeats use the same ntfy topic as other notifications -- verify you're subscribed.

The background heartbeat reads current state from `.gsd/.gsd-checkpoint.json` and reports total elapsed time, plus running cost data from `.gsd/costs/cost-summary.json` (current run cost, total cost, total tokens). To adjust the interval, modify the `-IntervalMinutes` parameter in the `Start-BackgroundHeartbeat` call within the pipeline scripts.

### Too many heartbeat notifications

Heartbeats are low-priority with hourglass emoji and include running cost data. Iteration-complete notifications use default priority with chart emoji and also include cost data. Terminal notifications (converged/stalled/max) include a detailed per-agent cost breakdown. In the ntfy app, you can:
- Filter by priority to hide low-priority heartbeats
- Mute heartbeats while keeping high-priority alerts (converged, stalled, timeout)

### "Agent Timeout" notification / watchdog killed agent

The watchdog timer (default: 30 minutes) killed a hung agent process. This means:

1. **The agent CLI froze**: It didn't produce output or exit within 30 minutes
2. **Auto-recovery in progress**: The engine halves the batch size and retries automatically
3. **Check logs**: Review `.gsd/logs/errors.jsonl` for `watchdog_timeout` entries

If this happens repeatedly for the same phase:
- The prompt may be too large -- reduce `-BatchSize` manually
- The agent's API may be experiencing issues -- check the agent's status page
- Network may be intermittent -- check connectivity

To adjust the timeout, modify `$script:AGENT_WATCHDOG_MINUTES` in resilience.ps1 (default 30).

### Notifications disabled / no ntfy output at startup

If you see no "ntfy topic" line at startup, notifications are not initialized. This happens when:
1. The resilience.ps1 module was not patched with notification functions (re-run install-gsd-all.ps1)
2. The global-config.json is missing or has invalid JSON

### "progress" command not getting a response

If you post "progress" to the ntfy topic and don't receive a `[GSD-STATUS]` response:

1. **Pipeline not running**: The command listener only runs while the pipeline is active. If the pipeline has exited (converged, stalled, or crashed), there is nothing listening for commands.
2. **Exact word required**: The listener only responds to the exact word "progress" (case-insensitive). Extra spaces, punctuation, or other text will be ignored.
3. **Topic mismatch**: Ensure you are posting to the exact same ntfy topic the pipeline is subscribed to. Check the topic printed at startup: `ntfy topic (auto): gsd-rjain-projectname`
4. **Reinstall**: If the command listener was not deployed, re-run `install-gsd-all.ps1` to ensure `Start-CommandListener` is available.

### Getting unsolicited [GSD-STATUS] responses

If you see `[GSD-STATUS]` messages you did not request, someone else (or another tool) is posting "progress" to your ntfy topic. Since ntfy topics are public by default:

1. **Use a unique topic**: Ensure your ntfy topic is not easily guessable. The auto-generated `gsd-{username}-{reponame}` format is usually unique enough.
2. **Check other sessions**: If you have multiple terminals running the same project, each pipeline has its own listener -- a single "progress" post will trigger responses from all of them.
3. **Feedback loop exclusion**: The listener ignores any message starting with `[GSD-STATUS]`, so it will not respond to its own output. If you are seeing repeated responses, another pipeline instance is likely running.

## LLM Council Issues

The LLM Council runs at 6 stages across both pipelines. Each stage uses 2-3 agents for independent review with Claude synthesizing the verdict.

### Council keeps blocking (health stuck at 99%)

The convergence council runs when health reaches 100%, before validation. If it blocks, health resets to 99% and the loop tries to fix the concerns. Max 2 convergence council attempts per pipeline run.

If council blocks twice:

1. **Read the council findings**: `.gsd/code-review/council-findings.md` has the detailed report with agent votes, concerns, and reasoning
2. **Check individual reviews**: `.gsd/logs/council-claude.log`, `council-codex.log`, `council-gemini.log`
3. **Check the verdict**: `.gsd/health/council-review.json` has the structured JSON verdict
4. **Common causes**:
   - Agents disagree on whether requirements are truly satisfied (false positives in health scoring)
   - Security/compliance concerns that the code review phase didn't catch
   - Implementation stubs counted as "satisfied" but council sees them as incomplete
5. **Override**: Set `"council": { "enabled": false }` in `global-config.json` to skip all council reviews

### Council auto-approves (quorum not met)

If fewer than the required agents respond successfully, the council auto-approves with a warning. This can happen if:

1. **Agent CLI not installed**: Gemini missing? Install with `npm install -g @google/gemini-cli`
2. **Prompt template missing**: Check `%USERPROFILE%\.gsd-global\prompts\council\` has all 14 templates (6 types x 2 + synthesis variants)
3. **Agent quota exhausted**: Council runs after iteration phases, so quota may be depleted
4. **Network issues**: Agent CLI can't reach API endpoint

### Council synthesis fails to parse

The synthesis agent (Claude) should return a JSON verdict. If parsing fails, the council auto-approves. Check `.gsd/logs/council-synthesis.log` for the raw output. The prompt template (`council/synthesize.md`) should instruct Claude to return **only** a JSON object.

### Post-research or pre-execute council slowing iterations

The post-research and pre-execute councils are non-blocking (feedback only, no retry). If they are adding too much latency:

1. **Disable council globally**: Set `"council": { "enabled": false }` in `global-config.json`
2. **These councils add ~$0.25 each** per iteration (2-agent review + synthesis)
3. **Check logs**: `.gsd/logs/council-*.log` for individual agent timing

### Post-blueprint council keeps regenerating manifest

The post-blueprint council reviews the blueprint manifest. If it blocks, the manifest is regenerated with council feedback. If this cycles:

1. **Check council feedback**: `.gsd/supervisor/council-feedback.md` contains the concerns injected into the next blueprint generation
2. **Common causes**: Blueprint is missing items that all 3 agents identify as required by specs
3. **Override**: Set `"council": { "enabled": false }` and run `gsd-blueprint -BuildOnly` to skip manifest regeneration

### Stall diagnosis council not finding root cause

The 3-agent stall diagnosis replaces the previous single-agent approach. If it's not helpful:

1. **Check diagnosis logs**: `.gsd/logs/council-claude.log`, `council-codex.log`, `council-gemini.log` during stall
2. **Review the stall-diagnosis.md**: Written to `.gsd/code-review/council-findings.md`
3. **The supervisor still runs**: After council diagnosis, the supervisor's Layer 2/3 analysis may provide additional fixes

## Final Validation Issues

### Validation keeps failing (health stuck at 99%)

The final validation gate runs when health reaches 100% and checks compilation, tests, SQL, and vulnerabilities. If validation fails, health is set to 99% and the loop continues to auto-fix. Max 3 validation attempts.

If validation fails 3 times:

1. **Check the validation log**: Review `.gsd/logs/final-validation.log` for exactly which checks failed
2. **Check the structured results**: Read `.gsd/health/final-validation.json` for per-check details
3. **Common causes**:
   - Build errors that agents can't fix (missing NuGet packages, incompatible .NET versions)
   - Test failures caused by missing test infrastructure (no test database, missing mock data)
   - npm build failures from missing dependencies not in package.json
4. **Fix manually and re-run**: Fix the underlying issue, then `gsd-converge` to resume

```powershell
# View validation results
Get-Content ".gsd\health\final-validation.json" | ConvertFrom-Json | Format-List

# View detailed log
Get-Content ".gsd\logs\final-validation.log"
```

### Validation skips all checks

If all 7 checks show "SKIP", the project may not have the expected build infrastructure:
- No `.sln` file → all .NET checks skipped
- No `package.json` → all npm checks skipped
- No test projects → test checks skipped (warning only)

This is normal for projects that don't use .NET or Node.js. The validation gate passes with no hard failures.

### Build passes locally but validation fails

The validation gate runs builds in the same working directory as the pipeline. Possible mismatches:

1. **Missing NuGet restore**: The gate runs `dotnet build --no-restore`. Ensure packages are restored first (normally handled by the engine's execute phase).
2. **Missing node_modules**: The gate runs `npm install --silent` if `node_modules` is missing, but network issues could cause this to fail.
3. **Environment-specific issues**: If builds depend on specific environment variables or tools not available in the pipeline context.

### npm test hangs / doesn't complete

The validation gate sets `CI=true` to prevent interactive watch mode (Jest, Vitest). If tests still hang:

1. **Watch mode not respecting CI**: Some test frameworks need explicit `--watchAll=false`. Update the test script in package.json.
2. **Test timeout**: Individual tests may be slow. The gate has a 5-minute overall timeout per check.
3. **Database dependencies**: Tests requiring a running database will fail in the pipeline context.

## Developer Handoff Issues

### developer-handoff.md is empty or missing sections

The handoff report gracefully handles missing data -- sections show "Data not available" or "*No {data} detected*" when source files don't exist. If a section is completely missing:

1. **Pipeline crashed before finally block**: The handoff is generated in the `finally` block. If PowerShell itself crashed (not the pipeline), the block may not run.
2. **`New-DeveloperHandoff` not available**: Re-run `install-gsd-all.ps1` to ensure `patch-gsd-final-validation.ps1` (Script 6) is installed.

### developer-handoff.md not committed to git

The handoff is committed and pushed in the `finally` block. If it's generated but not committed:

1. **Git authentication expired**: The push may fail silently. Check git credentials.
2. **No remote configured**: `git push` requires a configured remote. The commit is still local.
3. **Protected branch**: If the branch has push protection, the push will fail.

### Requirements table is empty

The requirements table reads from `requirements-matrix.json` (convergence) or `blueprint.json` (blueprint). If empty:

1. **No matrix generated yet**: Run at least one iteration of `gsd-converge` to create the requirements matrix.
2. **Blueprint manifest missing**: For blueprint pipeline, the manifest must be generated first via `gsd-blueprint -BlueprintOnly`.

### Health progression chart not showing

The ASCII chart reads from `health-history.jsonl`. If missing:

1. **No iterations completed**: At least one full iteration must complete to create a health history entry.
2. **Wrong path for blueprint**: Blueprint health history is at `.gsd/blueprint/health-history.jsonl`, not `.gsd/health/health-history.jsonl`.

## Supervisor Issues

### Supervisor keeps retrying the same fix

The supervisor tracks every diagnosis category + fix in `supervisor-state.json` to prevent repeating the same strategy. If it appears to be repeating:

1. Check `.gsd/supervisor/supervisor-state.json` for the attempts history
2. Review `.gsd/supervisor/diagnosis-{N}.md` files to see if Claude is diagnosing different root causes each time
3. The supervisor has built-in deduplication -- if the same category+fix combination appears twice, it skips to the next strategy

To reset supervisor state and start fresh:

```powershell
Remove-Item ".gsd\supervisor\supervisor-state.json" -Force
```

### How to read escalation-report.md

When the supervisor exhausts all strategies, it generates `.gsd/supervisor/escalation-report.md` with:

- **Summary**: What the supervisor tried and why it failed
- **All diagnoses**: Root-cause analysis from each attempt
- **Error statistics**: Aggregated errors by type/phase/agent
- **Recommended actions**: Specific human intervention steps

This report is designed to give you maximum context so you can fix the issue quickly.

### Resetting supervisor state

To clear all supervisor data and start a fresh recovery cycle:

```powershell
Remove-Item ".gsd\supervisor\*" -Force
```

To clear just the error context (so agents start without injected errors):

```powershell
Remove-Item ".gsd\supervisor\error-context.md" -Force
Remove-Item ".gsd\supervisor\prompt-hints.md" -Force
```

### Viewing pattern memory

The supervisor stores successful recovery patterns at `~/.gsd-global/supervisor/pattern-memory.jsonl`. To view:

```powershell
Get-Content "$env:USERPROFILE\.gsd-global\supervisor\pattern-memory.jsonl" | ForEach-Object { $_ | ConvertFrom-Json } | Format-Table pattern, category, fix, success, project
```

To clear pattern memory (e.g., if patterns are outdated):

```powershell
Remove-Item "$env:USERPROFILE\.gsd-global\supervisor\pattern-memory.jsonl" -Force
```

### Bypassing the supervisor

If the supervisor is interfering with debugging, bypass it entirely:

```powershell
gsd-converge -NoSupervisor       # Run pipeline directly
gsd-blueprint -NoSupervisor      # Run pipeline directly
```

### "Supervisor: NEEDS HUMAN" notification

This means the supervisor exhausted all recovery attempts (default 5). Read `.gsd/supervisor/escalation-report.md` for the full analysis. Common causes:

1. **Quota exhaustion**: All AI providers are rate-limited. Wait for billing cycle reset.
2. **Fundamental spec issues**: Specs are contradictory in a way that can't be auto-fixed. Review and correct the source specs.
3. **Architecture mismatch**: The existing codebase structure conflicts with spec requirements. Manual refactoring needed.

### Supervisor times out after 24 hours

The supervisor has a wall-clock time limit (`SUPERVISOR_TIMEOUT_HOURS`, default 24). If the supervisor loop exceeds this limit:

1. An escalation report is generated
2. An urgent notification is sent
3. The supervisor exits

This prevents supervisor loops that run indefinitely when all strategies fail slowly. To adjust:

```powershell
# The timeout is a constant in supervisor.ps1
# Default: $script:SUPERVISOR_TIMEOUT_HOURS = 24
```

### Debugging supervisor diagnosis files

Each supervisor attempt produces a `diagnosis-{N}.md` file in `.gsd/supervisor/`. To review what the supervisor found:

```powershell
# View all diagnosis files
Get-ChildItem ".gsd\supervisor\diagnosis-*.md" | ForEach-Object { Write-Host "=== $($_.Name) ==="; Get-Content $_.FullName; Write-Host "" }

# View the latest diagnosis
Get-ChildItem ".gsd\supervisor\diagnosis-*.md" | Sort-Object Name | Select-Object -Last 1 | ForEach-Object { Get-Content $_.FullName }
```

Each diagnosis contains: root cause, failure category, failing phase, error statistics, and recommended fix strategy. Compare consecutive diagnoses to see if the supervisor is converging on the right fix or if the root cause is shifting.

### Supervisor prompt hints persisting after fix

The supervisor writes `.gsd/supervisor/prompt-hints.md` with constraints for agents. These persist across pipeline restarts within a supervisor cycle. If the hints are no longer relevant (e.g., after manually fixing the issue):

```powershell
# Clear prompt hints
Remove-Item ".gsd\supervisor\prompt-hints.md" -Force

# Clear error context
Remove-Item ".gsd\supervisor\error-context.md" -Force

# Or clear all supervisor state for a fresh start
Remove-Item ".gsd\supervisor\*" -Force
```

Note: Prompt hints are injected into all agent prompts. Stale or incorrect hints can cause agents to apply unnecessary constraints. If agents are producing unexpected behavior after a supervisor cycle, check for leftover prompt-hints.md.

### Supervisor and final validation interaction

When the final validation gate fails (health set to 99%), the convergence loop continues. If the loop then stalls because it cannot fix the validation failures, the supervisor activates:

1. Supervisor reads the validation errors from `error-context.md`
2. Diagnoses the root cause (e.g., missing NuGet package, test database not configured)
3. Writes prompt-hints.md with specific fix instructions
4. Restarts the pipeline in a new terminal

This means the supervisor can help fix build/test failures that the normal convergence loop cannot resolve on its own. However, some validation failures require human intervention (e.g., missing test infrastructure, environment-specific dependencies).

## Engine Status Issues

### How to check if the engine is stalled

Read `.gsd/health/engine-status.json` and inspect the `state` and `last_heartbeat` fields:

```powershell
$status = Get-Content ".gsd\health\engine-status.json" | ConvertFrom-Json
Write-Host "State: $($status.state)"
Write-Host "Last heartbeat: $($status.last_heartbeat)"
Write-Host "Phase: $($status.phase) | Agent: $($status.agent) | Iteration: $($status.iteration)"
```

Interpret the results:

1. **state is "running"**: Check heartbeat freshness:
   - Less than 2 minutes old: **ACTIVE** -- engine is running normally
   - 2-5 minutes old: **PROBABLY ACTIVE** -- an agent call may be in progress
   - More than 5 minutes old: **LIKELY STALLED** -- the engine probably crashed without updating its state. Verify by checking if the PID is alive:
     ```powershell
     Get-Process -Id $status.pid -ErrorAction SilentlyContinue
     ```
2. **state is "sleeping"**: The engine is in a recoverable pause (quota backoff, rate limit). Check `sleep_until` to see when it should wake. If `sleep_until` is in the past, see the next troubleshooting entry.
3. **state is "stalled"**: The engine has detected an unrecoverable failure. Check `last_error` for details. The supervisor (if enabled) should pick this up automatically.
4. **state is "completed" or "converged"**: The pipeline finished. No action needed.

### engine-status.json shows "sleeping" but sleep_until is in the past

This indicates the engine likely crashed during a sleep/backoff period. The pipeline went to sleep for quota or rate-limit recovery but never woke up to update its state.

To recover:

1. Verify the pipeline process is dead:
   ```powershell
   $status = Get-Content ".gsd\health\engine-status.json" | ConvertFrom-Json
   Get-Process -Id $status.pid -ErrorAction SilentlyContinue
   ```
2. If no process is running, clear the lock and restart:
   ```powershell
   Remove-Item ".gsd\.gsd-lock" -Force
   gsd-converge    # or gsd-blueprint
   ```
3. The checkpoint system will resume from the last successful phase.

### engine-status.json is missing

The file is created when the pipeline first starts. If it does not exist:

1. **Pipeline never started**: Run `gsd-converge` or `gsd-blueprint` to start a pipeline. The file is created during the `starting` state.
2. **Directory was cleaned up**: If `.gsd/health/` exists but `engine-status.json` is missing, the file may have been manually deleted or the .gsd directory was partially cleaned. Re-running the pipeline will recreate it.
3. **Old installation**: If the engine was installed before the engine-status feature was added, re-run `install-gsd-all.ps1` to update the resilience module with `Update-EngineStatus`, `Start-EngineStatusHeartbeat`, and `Stop-EngineStatusHeartbeat`.

## Cost Tracking Issues

### Actual costs not being tracked

If `.gsd/costs/token-usage.jsonl` is not being populated:

1. **Re-install**: Run `install-gsd-all.ps1` to ensure `patch-gsd-hardening.ps1` (Script 5) has deployed the cost tracking functions (`Initialize-CostTracking`, `Save-TokenUsage`, `Extract-TokensFromOutput`)
2. **Check CLI version**: The JSON output flags require recent CLI versions. Older CLIs may not support `--output-format json` (Claude/Gemini) or `--json` (Codex). Update CLIs via `npm update -g`
3. **JSON parse failure**: If a CLI returns unexpected JSON format, the engine silently falls back to raw output and skips cost logging for that call. Check `.gsd/logs/` for raw agent output

### cost-summary.json is corrupted or out of sync

Rebuild the summary from the ground-truth JSONL file:

```powershell
# In a PowerShell session with GSD loaded
. "$env:USERPROFILE\.gsd-global\lib\modules\resilience.ps1"
Rebuild-CostSummary -GsdDir ".gsd"
```

This reads every line from `token-usage.jsonl` and reconstructs all aggregates (by agent, by phase, runs).

### -ShowActual shows no data

The `-ShowActual` flag on `gsd-costs` requires `.gsd/costs/cost-summary.json` to exist. This file is created when the first pipeline run starts. If you haven't run a pipeline yet, there is no actual cost data to display.

```powershell
# Verify cost data exists
Test-Path ".gsd\costs\cost-summary.json"
Get-Content ".gsd\costs\cost-summary.json" | ConvertFrom-Json | Select-Object total_calls, total_cost_usd
```

### Cost data missing after pipeline abort

The JSONL file is append-only, so all data up to the point of the crash is preserved. When you restart the pipeline, new cost entries are appended. The summary file is rebuilt incrementally on each new agent call.

If the summary is stale (e.g., pipeline crashed between JSONL write and summary update), rebuild it:

```powershell
. "$env:USERPROFILE\.gsd-global\lib\modules\resilience.ps1"
Rebuild-CostSummary -GsdDir ".gsd"
```

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

Gemini CLI supports two auth methods:
- **Google OAuth**: Uses your Google account subscription. Run `gemini` interactively once to trigger browser-based OAuth login.
- **API key** (recommended for pipelines): Set the `GOOGLE_API_KEY` environment variable via `setup-gsd-api-keys.ps1` or during installation (Step 0).

```powershell
# First-time setup (OAuth - opens browser)
gemini

# Or set API key (recommended for autonomous pipelines)
.\scripts\setup-gsd-api-keys.ps1 -GoogleKey "AIza..."

# Verify it works
"Say READY" | gemini --approval-mode plan 2>&1
```

If Gemini is down or unresponsive, the engine automatically falls back to Codex for research and spec-fix phases. No manual intervention required.

### Gemini exit code 44 (sandbox/Docker error)

**This issue has been resolved.** Older versions used `--sandbox` which required Docker/Podman. The engine now uses `--approval-mode plan` which provides the same read-only protection without requiring a container runtime. If you see exit code 44, re-run `install-gsd-all.ps1` to update.

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

### Parallel sub-tasks failing / partial success

When parallel execution is enabled and some sub-tasks fail:

1. **Partial success is normal**: Completed work is committed immediately; failed req_ids retry next iteration
2. **Check per-subtask logs**: Each sub-task writes to `.gsd/logs/iter{N}-4-sub{M}.log`
3. **Check errors.jsonl**: Failed sub-tasks log `subtask_failed` entries with the req_id and error
4. **Reduce concurrency**: Set `max_concurrent` to 1 in agent-map.json for sequential round-robin (easier to debug)
5. **Disable parallel entirely**: Set `execute_parallel.enabled` to `false` to revert to monolithic single-agent execute

```powershell
# Diagnose: check which sub-tasks failed
Get-Content ".gsd\logs\errors.jsonl" | ConvertFrom-Json | Where-Object { $_.category -eq "subtask_failed" }

# Reduce concurrency to sequential round-robin
# Edit %USERPROFILE%\.gsd-global\config\agent-map.json:
#   "max_concurrent": 1

# Disable parallel entirely (instant rollback)
# Edit %USERPROFILE%\.gsd-global\config\agent-map.json:
#   "enabled": false
```

If all sub-tasks fail and `fallback_to_sequential` is `true`, the engine automatically falls back to the original monolithic execute path. If the monolithic path also fails, batch reduction and stall handling proceed as normal.

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

## Token Cost Calculator Issues

### Pricing fetch fails / "Using hardcoded fallback pricing"

The calculator fetches pricing from the LiteLLM GitHub repository. If it fails:

1. **Network issue**: Verify internet connectivity and that `raw.githubusercontent.com` is not blocked by firewall
2. **GitHub rate limit**: Wait a few minutes and retry with `-UpdatePricing`
3. **LiteLLM repository changed**: The fallback hardcoded prices will be used. Check if the LiteLLM model_prices JSON URL has changed

```powershell
# Force-update pricing cache
gsd-costs -UpdatePricing

# Test the URL manually
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json" -UseBasicParsing | Select-Object StatusCode
```

### "Pricing cache is stale (X days old)"

The cache at %USERPROFILE%\.gsd-global\pricing-cache.json is older than 60 days. The calculator will attempt auto-refresh. If refresh fails:

```powershell
# Delete stale cache and force refresh
Remove-Item "$env:USERPROFILE\.gsd-global\pricing-cache.json" -Force
gsd-costs -UpdatePricing
```

### Pricing shows wrong model names or prices

The LiteLLM database model keys may have changed. The calculator tries multiple key variants per model (e.g., `claude-opus-4-6`, `claude-opus-4-5`). If a new model version is released:

1. Check the current cache: `Get-Content "$env:USERPROFILE\.gsd-global\pricing-cache.json" | ConvertFrom-Json | ConvertTo-Json -Depth 5`
2. Force refresh: `gsd-costs -UpdatePricing`
3. If the model key format changed in LiteLLM, update the `$modelLookups` array in `token-cost-calculator.ps1`

### Blueprint.json not found / auto-detection fails

The calculator's auto mode requires `.gsd\blueprint\blueprint.json` in the project. If not found:

```powershell
# Use manual parameters instead
gsd-costs -TotalItems 150 -CompletedItems 30

# Or specify the project path explicitly
gsd-costs -ProjectPath "C:\repos\my-app"
```

### Client quote shows incorrect complexity tier

Complexity is auto-determined by item count: Standard (<=100), Complex (<=250), Enterprise (<=500), Enterprise+ (>500). Override by adjusting the `-Markup` parameter:

- Simple projects: `-Markup 5`
- Medium projects: `-Markup 7` (default)
- Complex/enterprise: `-Markup 10`

### Cost estimate seems too low

The calculator models the "happy path" and may underestimate due to:

- Build errors requiring diagnosis loops (not modeled)
- Growing input context as codebase grows
- Health regression requiring reverts and retries
- "Last mile" problem (80% to 100% costs more per-item than 0% to 80%)

Use `-ClientQuote` with a 7-10x markup to account for these factors. The three-tier pricing (best/expected/worst) provides a range.

## Remote Monitoring Issues

### gsd-remote not connecting / QR code not scanning

The `gsd-remote` command launches a Claude remote session and displays a QR code for phone access. If it fails:

1. **Claude CLI not authenticated**: Run `claude` interactively first to ensure authentication is active
2. **QR code unreadable**: Increase terminal font size or zoom in. The QR code requires a minimum display size.
3. **Phone can't connect after scanning**: Ensure your phone has internet access and is not on a VPN that blocks the connection
4. **Session disconnects**: The remote session stays active only while the terminal is open. Press Ctrl+C to stop cleanly.

### gsd-remote vs ntfy notifications

`gsd-remote` gives interactive access to a Claude session, while ntfy provides passive push notifications. For overnight monitoring, ntfy is recommended since it doesn't require keeping a terminal session open.

## Blueprint Pipeline Stalls

### Blueprint stall at high percentage (90%+)

The "last mile" problem -- the final items are often the most complex (cross-cutting concerns, integration points). Options:

1. **Reduce batch size**: `gsd-blueprint -BatchSize 3 -BuildOnly` to focus on fewer items per cycle
2. **Check remaining items**: Review `.gsd/blueprint/blueprint.json` for items still at "pending" or "partial"
3. **Use convergence**: Switch to `gsd-converge` which handles iterative fix-and-verify better for the remaining gaps

### Blueprint produces manifest but build fails repeatedly

The build phase (Codex) may struggle with complex items. Options:

1. **Resume build only**: `gsd-blueprint -BuildOnly` skips regenerating the manifest
2. **Verify only**: `gsd-blueprint -VerifyOnly` re-scores without building (useful after manual fixes)
3. **Check build logs**: Review `.gsd/logs/iter{N}-*.log` for the specific build errors
4. **Switch to convergence**: After blueprint gets to 60-80%, `gsd-converge` can fix remaining issues

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
