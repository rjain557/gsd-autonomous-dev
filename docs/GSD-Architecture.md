# GSD Engine Architecture

## Overview

The GSD Engine orchestrates seven AI agents (3 CLI-based + 4 REST API) through PowerShell scripts to autonomously develop, fix, and verify code against specifications. It runs unattended with comprehensive self-healing for network failures, quota limits, disk space, JSON corruption, agent boundary violations, and stalls.

The multi-model strategy distributes work across independent quota pools: Claude (claude-sonnet-4-6) handles reasoning (review, plan, verify), Codex (gpt-5.4) handles code generation (execute), and Gemini (gemini-3.0-pro) handles research and spec-fix. Four additional REST API agents (Kimi K2.5, DeepSeek V3, GLM-5, MiniMax M2.5) expand the rotation pool — when any CLI agent exhausts its quota, the engine immediately rotates to the next available agent instead of waiting in sleep loops.

Model versions are controlled by `agent_models` in `global-config.json` and passed via `--model` flag to every CLI invocation. Changing model versions requires only a config edit — no reinstall needed.

## Installed Directory Structure

After running install-gsd-all.ps1, the engine creates:

```
%USERPROFILE%\.gsd-global\
  bin\                          # CLI wrappers (added to PATH)
    gsd-converge.cmd            # Convergence loop launcher
    gsd-blueprint.cmd           # Blueprint pipeline launcher
    gsd-status.cmd              # Health status dashboard
    gsd-remote.cmd              # Remote monitoring launcher
    gsd-costs.cmd               # Token cost calculator
    gsd-fix.cmd                 # Quick bug fix mode
    gsd-update.cmd              # Incremental feature update
  config\
    global-config.json          # Global settings (notifications, patterns, phases)
    agent-map.json              # Agent-to-phase assignments, parallel config, council reviewers
    model-registry.json         # Multi-model registry (CLI + REST agent metadata, rotation pool)
  lib\modules\
    resilience.ps1              # Retry, checkpoint, lock, rollback, adaptive batch, hardening, final validation
    interfaces.ps1              # Multi-interface detection + auto-discovery
    interface-wrapper.ps1       # Context builder for agent prompts
  prompts\
    claude\                     # Claude Code prompt templates (review, plan, verify)
    codex\                      # Codex prompt templates (execute, research fallback)
    gemini\                     # Gemini prompt templates (research, spec-fix)
    council\                    # Council prompt templates (15 templates: 6 types x 2 + synthesis variants + openai-compat-review)
  blueprint\
    scripts\
      blueprint-pipeline.ps1    # Blueprint generation + build loop
      supervisor-blueprint.ps1  # Supervisor wrapper for blueprint
      assess.ps1                # Assessment script (gsd-assess)
  scripts\
    convergence-loop.ps1        # 5-phase convergence engine
    supervisor-converge.ps1     # Supervisor wrapper for convergence
    gsd-profile-functions.ps1   # PowerShell profile (gsd-* commands)
    token-cost-calculator.ps1   # Token cost estimator (gsd-costs)
  pricing-cache.json              # Cached LLM pricing data (auto-updated)
  supervisor\
    pattern-memory.jsonl          # Cross-project failure patterns + fixes
  VERSION                       # Installed version stamp
```

## Per-Project State (.gsd/ folder)

When you run gsd-assess or gsd-converge in a repo, it creates:

```
.gsd\
  assessment\
    assessment-summary.md       # Human-readable findings
    work-classification.json    # Skip/fix/build/review per item
    backend-inventory.json      # C# layer detail
    database-inventory.json     # SQL layer detail
    frontend-inventory.json     # React layer detail
    file-inventory.json         # Complete file catalog
  health\
    health-current.json         # Current score + breakdown
    health-history.jsonl        # Scores over time
    requirements-matrix.json    # Every requirement + status
    drift-report.md             # Human-readable gap analysis
    engine-status.json          # Live engine state (stall detection, heartbeat)
  code-review\                  # Detailed review findings
  generation-queue\
    queue-current.json          # Prioritized next batch
  agent-handoff\
    current-assignment.md       # Detailed instructions for Codex
    handoff-log.jsonl           # Execution log
  spec-conflicts\
    conflicts-to-resolve.json   # Detected spec contradictions
    resolution-summary.md       # Auto-resolution results
  costs\
    token-usage.jsonl             # Actual token costs per agent call (append-only)
    cost-summary.json             # Rolling cost totals by agent, phase, run
  health\
    final-validation.json         # Final validation gate results (7 checks)
  logs\
    errors.jsonl                # Categorized errors (JSONL)
    final-validation.log        # Detailed final validation output
    iter{N}-{phase}.log         # Per-iteration agent output
  file-map.json                 # Machine-readable repo inventory
  file-map-tree.md              # Human-readable directory tree
  spec-consistency-report.md    # Spec conflict analysis
  supervisor\
    supervisor-state.json         # Supervisor attempts, strategies, diagnoses
    last-run-summary.json         # Pipeline exit state (reason, health, iteration)
    diagnosis-{N}.md              # Root-cause analysis for attempt N
    error-context.md              # Injected into agent prompts (last iteration errors)
    prompt-hints.md               # Extra instructions from supervisor
    agent-override.json           # Agent reassignment (e.g., {"execute": "claude"})
    escalation-report.md          # Full report when all strategies exhausted
  .gsd-checkpoint.json          # Crash recovery state (also read by background heartbeat)
  .gsd-lock                     # Prevents concurrent runs
developer-handoff.md              # Auto-generated developer handoff report (repo root)
```

## Data Flow

### gsd-assess

1. Detect interfaces (recursive scan for design\{type}\v## + auto-detect API from .sln/.csproj + Database from .sql files)
2. Auto-discover _analysis/ and _stubs/ within each interface
3. Generate file map (JSON + tree)
4. Send assessment prompt to Claude with file map + interface context
5. Claude produces work classification and inventories

### gsd-converge (per iteration)

1. PRE-FLIGHT: CLI version check, network test, disk space, spec consistency
2. REVIEW: Claude reviews code, identifies issues, scores health
3. RESEARCH: Gemini (plan mode, read-only) researches patterns; falls back to Codex if unavailable
4. POST-RESEARCH COUNCIL: 2-agent review of research findings (Claude + Codex)
5. PLAN: Claude creates fix plan with prioritized batch
6. PRE-EXECUTE COUNCIL: 2-agent review of execution plan (Claude + Gemini)
7. EXECUTE: Codex makes code changes (parallel sub-tasks when enabled)
8. VERIFY: Claude re-scores health, commits if improved
9. POST-ITERATION: File map update, checkpoint save, notification
10. STALL DIAGNOSIS COUNCIL: 3-agent collaborative diagnosis if health stalls
11. CONVERGENCE COUNCIL (at 100% health): 3 agents independently review, Claude synthesizes verdict
    - Note: Steps 2-10 only run when health < 100%. Use `-ForceCodeReview` to force one review iteration at 100%.
12. FINAL VALIDATION: Build, test, SQL, audit checks (hard failures reset to 99%)

### gsd-blueprint

1. PRE-FLIGHT: CLI version check, network test, disk space, spec consistency
2. GENERATE: Claude creates blueprint manifest from _analysis/ specs
3. POST-BLUEPRINT COUNCIL: 3-agent review of manifest completeness and feasibility
4. BUILD: Codex generates code for each blueprint item (adaptive batch)
5. VERIFY: Claude verifies against specs with storyboard tracing, scores health
6. STALL DIAGNOSIS COUNCIL: 3-agent collaborative diagnosis if health stalls
7. Repeat until 100% or stalled

## Agent Assignment (Multi-Model Strategy)

### Primary Agents (CLI-based)

| Phase | Agent | Mode | Why |
|-------|-------|------|-----|
| Review | Claude | `--allowedTools Read,Write,Bash` | Better at architectural analysis |
| Research | **Gemini** | `--approval-mode plan` (read-only; requires `experimental.plan: true` in gemini settings) | Saves Claude/Codex quota; falls back to Codex |
| Plan | Claude | `--allowedTools Read,Write,Bash` | Better at strategic planning |
| Execute | Codex (or parallel pool) | `--full-auto` | Faster at bulk code generation; parallel mode round-robins across agents |
| Verify | Claude | `--allowedTools Read,Write,Bash` | Better at spec compliance checking |
| Council Review | Claude + Codex + **Gemini** + REST agents | Independent parallel reviews | Multi-agent cross-validation at 100% health |
| Council Synthesize | Claude | Reads all reviews | Produces consensus verdict (approve/block) |
| Spec-Fix | **Gemini** | `--yolo` (write) | Saves Claude/Codex quota for code gen |
| Blueprint | Claude | `--allowedTools Read,Write,Bash` | Better at spec-to-manifest generation |
| Build | Codex | `--full-auto` | Faster at code generation from specs |

### REST API Agents (OpenAI-compatible)

| Agent | Provider | Model ID | Input $/M | Output $/M |
|-------|----------|----------|-----------|------------|
| kimi | Moonshot AI | kimi-k2.5 | $0.60 | $2.50 |
| deepseek | DeepSeek | deepseek-chat | $0.28 | $0.42 |
| glm5 | Zhipu AI | glm-5 | $1.00 | $3.20 |
| minimax | MiniMax | MiniMax-M2.5 | $0.29 | $1.20 |

REST agents participate in:
- **Agent rotation**: When a CLI agent hits quota, the engine rotates to the next available REST agent
- **Parallel execute pool**: Added to the `execute_parallel.agent_pool` for sub-task distribution
- **Council reviews**: Added to `council.reviewers` for expanded cross-validation
- **Supervisor fallback**: L2 diagnosis can use a REST agent when Claude is in cooldown

REST agents use the OpenAI-compatible chat completions API (text-in/text-out). They do not support file-system tool use, so they handle text generation sub-tasks only. Full agentic file editing stays with CLI agents.

Token budgets are optimized across seven independent quota pools:
- Claude Code: 4 reasoning phases (review, create-phases, plan, verify) = ~5K tokens each
- Codex: 1 execution phase (execute) = ~65K tokens per iteration
- Gemini: 2 supporting phases (research, spec-fix) = ~10K tokens per iteration
- Kimi/DeepSeek/GLM-5/MiniMax: rotation fallbacks + parallel sub-tasks + council reviews

### Why Seven Models?

Each agent draws from an independent API quota pool. This means:
- Claude quota exhaustion does NOT block Gemini research or Codex execution
- Codex quota exhaustion triggers immediate rotation to the next available agent (kimi, deepseek, glm5, or minimax) instead of a 5-minute sleep loop
- Gemini handles the "unlimited reading" work that previously burned through Codex quota
- REST agents provide 4 additional fallback pools, dramatically reducing total wait time during quota exhaustion
- Overall throughput increases because 7 agents across 7 providers virtually eliminates quota-induced stalls

### API Key Authentication

Each CLI agent supports two authentication methods: interactive login (OAuth) and API key environment variables. REST API agents require API keys (no CLI to authenticate interactively).

#### CLI Agent Keys

| Environment Variable | CLI | Expected Prefix | Purpose |
|---------------------|-----|----------------|---------|
| ANTHROPIC_API_KEY | Claude Code | sk-ant- | Review, plan, verify, blueprint phases |
| OPENAI_API_KEY | Codex | sk- | Execute, build phases |
| GOOGLE_API_KEY | Gemini | AIza | Research, spec-fix phases |

CLI agent API keys are configured during installation (Step 0 of `install-gsd-global.ps1`) or via `setup-gsd-api-keys.ps1`. If not set, CLI agents fall back to interactive OAuth (which may have lower rate limits).

#### REST Agent Keys

| Environment Variable | Provider | Agent Name | Key Source |
|---------------------|----------|-----------|-----------|
| KIMI_API_KEY | Moonshot AI | kimi | https://platform.moonshot.ai |
| DEEPSEEK_API_KEY | DeepSeek | deepseek | https://platform.deepseek.com |
| GLM_API_KEY | Zhipu AI | glm5 | https://z.ai |
| MINIMAX_API_KEY | MiniMax | minimax | https://platform.minimaxi.com |

REST agent API keys are optional. Agents without keys are automatically excluded from the rotation pool. Set keys as User-level environment variables:

```powershell
[System.Environment]::SetEnvironmentVariable("KIMI_API_KEY", "your-key-here", "User")
[System.Environment]::SetEnvironmentVariable("DEEPSEEK_API_KEY", "your-key-here", "User")
[System.Environment]::SetEnvironmentVariable("GLM_API_KEY", "your-key-here", "User")
[System.Environment]::SetEnvironmentVariable("MINIMAX_API_KEY", "your-key-here", "User")
```

The engine checks environment variables in order: Process → User → Machine. Keys set at User or Machine level are automatically loaded into the current session at preflight time, so you do not need to restart your terminal after setting them.

All API keys are stored as persistent environment variables (Windows registry), never committed to git.

### Gemini Fallback

If the Gemini CLI (`gemini`) is not installed, the engine automatically falls back to Codex for research and spec-fix phases. Install Gemini CLI to get the full benefit of the core 3-model phase routing and the broader 7-model architecture:

```
npm install -g @google/gemini-cli
gemini    # first run authenticates
```

## Parallel Sub-Task Execution

When `execute_parallel.enabled` is `true` in `agent-map.json`, the execute phase splits the batch into independent sub-tasks instead of sending the entire batch as a single monolithic prompt.

### How It Works

1. **Decompose**: Each item in `queue-current.json.batch[]` becomes a standalone sub-task
2. **Assign agents**: Sub-tasks are distributed across the agent pool (default: codex, claude, gemini) using round-robin or all-same strategy
3. **Dispatch in waves**: Up to `max_concurrent` sub-tasks run simultaneously as PowerShell background jobs, each calling `Invoke-WithRetry` with `MaxAttempts: 2`
4. **Wave cooldown**: 10-second pause between concurrent waves prevents burst quota triggers
5. **Aggregate results**: Success (all passed), PartialSuccess (some passed), or AllFailed

### Partial Success Handling

When some sub-tasks succeed and others fail:
- Completed work is committed and pushed immediately
- Failed sub-task req_ids are logged for the next iteration to retry
- Commit message includes `[partial: N/M]` annotation

### Fallback to Monolithic

If all sub-tasks fail and `fallback_to_sequential` is `true`, the engine falls through to the original single-agent monolithic execute path. Set `execute_parallel.enabled` to `false` for instant rollback to pre-parallel behavior.

### Configuration

Located in `agent-map.json` under the `execute_parallel` key:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| enabled | bool | true | Master switch; false = monolithic behavior |
| max_concurrent | int | 3 | Max parallel agent jobs per wave |
| agent_pool | string[] | ["codex","claude","gemini"] | Agents to rotate through |
| strategy | string | "round-robin" | "round-robin" or "all-same" |
| fallback_to_sequential | bool | true | Fall back to monolithic if all sub-tasks fail |
| subtask_timeout_minutes | int | 30 | Per-subtask watchdog timeout |

## Resilience Features

### Retry with Batch Reduction

Failed agent calls retry 3 times. Each retry halves the batch size (15 -> 7 -> 3 -> 2). Minimum batch is 2. Two different reduction factors apply:

- **Agent failure/watchdog timeout** (in `Invoke-WithRetry`): reduces by 50% (`BATCH_REDUCTION_FACTOR = 0.5`)
- **Stall** (no health progress in pipeline loop): reduces by 25% (multiplied by `0.75`), giving agents a slightly larger batch to work with since the issue is stagnation, not crashes

### Checkpoint Recovery

After each successful phase, state is saved to .gsd-checkpoint.json. On restart, the engine resumes from the last checkpoint. Stores pipeline, iteration number, phase, health score, batch size, status, and process ID.

### Lock File

.gsd-lock prevents concurrent GSD runs in the same repo. Lock includes timestamp for stale detection (auto-cleared after 120 min).

### Quota Management

Detects "quota exhausted" or "rate limit" in agent output. On first quota failure, the engine immediately rotates to the next available agent (from a pool of 7) instead of waiting. If all agents are exhausted, adaptive backoff starts: 5 minutes, doubles each cycle (5 -> 10 -> 20 -> 40 -> 60 -> 60 min cap). Cumulative quota wait capped at 2 hours. Differentiates rate_limit (wait 2 min) vs quota_exhausted (rotate immediately, then wait if all exhausted).

### Proactive Throttling

Adds configurable delays between agent calls to prevent hitting quota limits during long runs. Default: 30 seconds between phases. Configurable via -ThrottleSeconds parameter on both gsd-converge and gsd-blueprint.

### Network Polling

Tests network by running: claude -p "PING" --max-turns 1

Polls every 30 seconds when offline. Resumes when connectivity returns. Max wait: 1 hour.

### Git Snapshots and Commit Traceability

Creates git snapshot before any destructive operation. After each successful iteration, the engine commits all changes with the code review text as the commit message body. This documents exactly what was reviewed, found, and fixed in each iteration.

**Convergence pipeline**: Reads `.gsd/code-review/review-current.md` and uses it as the commit body via `git commit -F`.

**Blueprint pipeline**: Uses the drift report and health data as the commit body.

Commit messages follow this format:
```
gsd: iter N (health: X%)

[Full code review text, truncated at 4000 characters]
```

All iteration commits are automatically pushed to the remote repository (`git push`). The final CONVERGED/COMPLETE commit includes a `gsd-converged-vN` tag that is also pushed.

### Health Regression Protection

Detects health drops greater than 5% after an iteration. Auto-reverts git to pre-iteration state and increments stall counter to prevent repeated regressions.

### JSON Corruption Protection

Validates JSON after every agent write. Automatic restore from .last-good backup if corruption detected. Recovery events are logged.

### Disk Space Management

Per-iteration disk checks requiring 0.5 GB minimum free space. Auto-cleanup of node_modules/.cache, bin/obj, old logs when space is low.

### Agent Boundary Enforcement

Prevents agents from writing outside their allowed scope:
- Claude can ONLY write to .gsd/ (never source code)
- Codex can ONLY write source code (never .gsd/health, .gsd/code-review, .gsd/generation-queue)
- Gemini (research/plan mode) must NOT modify ANY files (read-only mode)
- Gemini (spec-fix) can ONLY modify docs/ and .gsd/spec-conflicts/ (never source code)
- Auto-reverts boundary violations with git checkout

### Watchdog Timeout

Agent CLI processes are monitored with a configurable watchdog timer (default: 30 minutes). If an agent hangs (e.g., stuck on an oversized prompt or API deadlock), the watchdog:

1. Kills the hung process and all child processes
2. Sends a high-priority push notification ("Agent Timeout: claude")
3. Logs a `watchdog_timeout` entry to errors.jsonl
4. Halves the batch size (smaller prompt = less likely to hang)
5. Retries the phase with the reduced batch

The watchdog is configured via `$script:AGENT_WATCHDOG_MINUTES` in resilience.ps1 (default 30). Each agent call runs in an isolated child process, so killing it does not affect the parent pipeline.

### Supervisor (Self-Healing Recovery)

When the pipeline stalls, hits max iterations, or fails repeatedly, the supervisor acts like a senior developer: it reads logs, root-causes the actual problem, modifies prompts/specs/queue/matrix to fix it, kills the stuck pipeline, opens a new terminal, and restarts.

#### Architecture

```
User runs: gsd-converge
  -> supervisor-converge.ps1 (wrapper)
      -> convergence-loop.ps1 (existing pipeline)
          [runs until: converged / stalled / max-iter / error]
      <- pipeline writes last-run-summary.json, exits
      -> Layer 1: Get-ErrorStatistics (parse errors.jsonl - no AI cost)
      -> Layer 2: Invoke-SupervisorDiagnosis (Claude reads logs, root-causes issue)
      -> Layer 3: Invoke-SupervisorFix (Claude modifies prompts/queue/matrix/specs)
      -> Stop current script, open NEW terminal, restart pipeline
      ... (up to 5 attempts, then escalate with full report)
```

#### Three-Layer Analysis

| Layer | Cost | Function | What It Does |
|-------|------|----------|--------------|
| 1 | Free | Pattern matching | Parse errors.jsonl statistics, find stuck requirements, analyze health trajectory |
| 2 | 1 Claude call | Root-cause diagnosis | Claude reads all logs + matrix + stall-diagnosis, outputs structured diagnosis JSON |
| 3 | 1 Claude call | Fix application | Claude modifies prompts/queue/matrix/specs based on diagnosis |

#### Failure Categories

| Category | Description | Fix Strategy |
|----------|-------------|--------------|
| stuck_requirements | Requirements stuck at "partial" for 3+ iterations | Decompose into sub-requirements, clarify specs |
| agent_failures | Agent crashes or produces invalid output | Reassign to different agent, simplify prompt |
| build_loop | Build errors repeating across iterations | Write error context into prompts, add constraints |
| regression_loop | Health oscillating (fix one thing, break another) | Add regression guards to prompt hints |
| phase_timeout | Agent hangs repeatedly on same phase | Reduce batch, reassign agent, simplify instructions |
| quota_exhaustion | All retries exhausted on quota limits | Escalate (requires human intervention) |
| spec_ambiguity | Specs are ambiguous/contradictory causing divergent output | Write clarification notes into prompt hints |

#### Error Context Injection

After each iteration, the supervisor writes `.gsd/supervisor/error-context.md` with details of what failed and why. This file is automatically injected into every agent prompt in the next iteration via `Local-ResolvePrompt`. Agents receive the errors, root cause, and explicit instructions to avoid repeating the same mistakes.

Additionally, `.gsd/supervisor/prompt-hints.md` contains extra constraints and instructions written by the supervisor based on its diagnosis. Both files are appended to prompts for all agents (Claude review, Claude plan, Codex execute).

#### Agent Override

The supervisor can reassign phases to different agents by writing `.gsd/supervisor/agent-override.json`:

```json
{"execute": "claude", "build": "gemini"}
```

This overrides the default agent for that phase in the next pipeline run. Used when an agent consistently fails on a specific type of task.

#### Pattern Memory (Cross-Project Learning)

Successful recovery patterns are saved to `~/.gsd-global/supervisor/pattern-memory.jsonl`. When a new failure occurs, the supervisor checks this database first. If a known fix exists for a matching failure pattern, it's applied immediately without AI cost.

```jsonl
{"pattern":"build_error_missing_namespace","category":"build_loop","fix":"Rewrite prompt-hints to specify exact namespace","success":true,"project":"patient-portal","timestamp":"2026-03-02T15:00:00Z"}
```

#### Loop Control (Prevents Infinite Retries)

1. **Hard budget**: Max 5 attempts (configurable via `-SupervisorAttempts`), then escalate
2. **Strategy deduplication**: Each diagnosis category + fix is tracked; same fix never repeated
3. **Health monotonicity**: If health drops across 3+ supervisor attempts, escalate immediately
4. **Time budget**: 24-hour wall-clock limit
5. **Pattern memory**: Known fixes tried first, unknown failures get AI diagnosis
6. **Escalation is terminal**: Generates comprehensive report and sends urgent notification

### Structured Error Logging

All errors logged to .gsd/logs/errors.jsonl with categories: quota, network, disk, corrupt_json, boundary_violation, agent_crash, health_regression, spec_conflict, watchdog_timeout, build_fail, fallback_success, validation_fail. Each entry includes timestamp, phase, iteration, message, and resolution.

## Push Notifications (ntfy.sh)

The engine sends real-time push notifications to your phone via ntfy.sh (free, no account required).

### Auto-Detection

When multiple projects run simultaneously, each gets its own notification channel. The topic is auto-generated from your environment:

```
Pattern: gsd-{username}-{reponame}
```

- **Username**: Read from $env:USERNAME (Windows) or $env:USER (Linux/macOS)
- **Repo name**: Extracted from git remote origin URL, falls back to directory name
- **Sanitization**: Lowercased, special characters replaced with hyphens (dots, underscores, spaces all become -)

Examples:

| Project Repo | ntfy Topic |
|---|---|
| patient-portal | gsd-rjain-patient-portal |
| billing-api.v2 | gsd-rjain-billing-api-v2 |
| admin_dashboard | gsd-rjain-admin-dashboard |

### Topic Priority

The topic is resolved in this order:
1. Explicit -NtfyTopic parameter (highest priority)
2. ntfy_topic value in global-config.json (if not "auto")
3. Auto-detected from username + repo name (default)

### Notification Events

| Event | Title | Priority | Tags |
|-------|-------|----------|------|
| Pipeline start | "GSD Converge Started" / "GSD Blueprint Started" | default | rocket |
| Heartbeat | "Working: {phase}" (+ cost) | low | hourglass_flowing_sand |
| Agent timeout | "Agent Timeout: {agent}" | high | skull |
| Iteration complete | "Iter N Complete" / "Blueprint Iter N" (+ cost) | default | chart_with_upwards_trend |
| No progress (stall) | "Iter N: No Progress" | default | hourglass |
| Execute/build failed | "Iter N: Execute Failed" / "Iter N: Build Failed" | default | warning |
| Regression reverted | "Iter N: Regression Reverted" | high | warning |
| Converged / Complete | "CONVERGED!" / "BLUEPRINT COMPLETE!" (+ detailed cost) | high | tada, white_check_mark |
| Stalled (threshold) | "STALLED" / "BLUEPRINT STALLED" (+ detailed cost) | high | warning |
| Max iterations | "MAX ITERATIONS" / "Blueprint Max Iterations" (+ detailed cost) | high | warning |
| Supervisor active | "Supervisor Active" | low | robot_face |
| Supervisor diagnosis | "Supervisor: {root_cause}" | default | mag |
| Supervisor fix applied | "Supervisor: Fixed - {description}" | default | wrench |
| Supervisor restarting | "Supervisor: Restarting in new terminal" | default | rocket |
| Supervisor recovered | "Supervisor: RECOVERED at {health}%" | high | white_check_mark |
| Supervisor escalation | "Supervisor: NEEDS HUMAN - see escalation-report.md" | urgent | sos |
| Validation failed | "Validation Failed (N/3)" | high | warning |
| Validation passed | "Validation Passed" | default | white_check_mark |
| Progress response | "[GSD-STATUS] Progress Report" (+ detailed cost) | default | bar_chart |

#### Background Heartbeat

A background PowerShell job runs independently of the main pipeline, sending progress notifications every 10 minutes even while a single agent call is executing. This solves the problem of long-running agent calls (15-30+ minutes) blocking all notification output.

The background heartbeat:
- Starts automatically when the pipeline starts
- Reads current state from `.gsd-checkpoint.json` (phase, iteration, health)
- Sends an ntfy notification every 10 minutes with total elapsed time
- Stops automatically when the pipeline exits (including crashes, via the `finally` block)

Example notification during a long code-review call:
```
Title: Working: code-review
Body:  patient-portal | Iter 1 | Health: 45% | 20m total
       Cost: $1.24 run / $3.18 total | 412K tok
```

Agent timeout notifications fire when the watchdog kills a hung agent process (default: 30 minutes). These are high-priority alerts that indicate a retry is in progress.

#### Command Listener

A background PowerShell job polls the ntfy topic every 15 seconds for user commands. When a user posts the exact word "progress" (case-insensitive) to the ntfy topic, the listener reads the checkpoint and health files and responds with a formatted progress report posted back to the same topic.

Only the word "progress" is recognized -- everything else is silently ignored. Responses are prefixed with `[GSD-STATUS]` to avoid feedback loops (the listener ignores any message starting with this prefix).

Example response posted back to the ntfy topic:
```
[GSD-STATUS] Progress Report
patient-portal | converge pipeline
Health: 72% | Iter: 5 | Phase: execute
Items: 25 done / 8 partial / 7 todo (of 40)
Batch: 8 | Elapsed: 45m
Cost: $2.87 run / $4.52 total | 623K tok (claude $2.91, codex $0.84, gemini $0.77)
```

The command listener:
- Starts automatically when the pipeline starts (alongside the background heartbeat)
- Polls the ntfy topic every 15 seconds for new messages
- Only responds to the exact word "progress" (case-insensitive)
- Stops automatically when the pipeline exits (including crashes, via the `finally` block)

### Mobile Setup

1. Install the ntfy app on your phone (iOS App Store or Google Play)
2. Run any pipeline once -- the topic name prints at startup: `ntfy topic (auto): gsd-rjain-patient-portal`
3. In the ntfy app, subscribe to that topic name
4. Repeat for each project you want to monitor

Each project publishes to its own topic, so notifications are grouped by project on your phone.

## Engine Status File

### Purpose

`.gsd/health/engine-status.json` is a live state file updated at every state transition and on a 60-second heartbeat interval. It allows external observers (dashboards, scripts, the supervisor) to distinguish between "crashed," "sleeping in recoverable backoff," and "actively running" without parsing logs or checking process tables.

### File Location

`.gsd\health\engine-status.json` (within the per-project .gsd directory)

### Schema

```json
{
  "pid": 23340,
  "state": "running",
  "phase": "research",
  "agent": "gemini",
  "iteration": 4,
  "attempt": "1/3",
  "batch_size": 8,
  "health_score": 87.5,
  "last_heartbeat": "2026-03-02T22:27:00Z",
  "started_at": "2026-03-02T22:00:00Z",
  "elapsed_minutes": 27,
  "sleep_until": null,
  "sleep_reason": null,
  "last_error": null,
  "errors_this_iteration": 0,
  "recovered_from_error": false
}
```

| Field | Type | Description |
|-------|------|-------------|
| pid | int | OS process ID of the running pipeline |
| state | string | Current engine state (see state table below) |
| phase | string | Current pipeline phase (e.g., "review", "research", "plan", "execute", "verify") |
| agent | string | Active agent ("claude", "codex", "gemini") |
| iteration | int | Current iteration number |
| attempt | string | Retry attempt in "N/M" format (e.g., "1/3") |
| batch_size | int | Current batch size (may be reduced from retries) |
| health_score | number | Latest health score percentage |
| last_heartbeat | string | ISO 8601 timestamp of the last heartbeat update |
| started_at | string | ISO 8601 timestamp when the pipeline started |
| elapsed_minutes | number | Total minutes since pipeline start |
| sleep_until | string/null | ISO 8601 timestamp when sleep ends (null if not sleeping) |
| sleep_reason | string/null | Reason for sleep (e.g., "quota_backoff", "rate_limit") |
| last_error | string/null | Last error message (truncated to 200 chars) |
| errors_this_iteration | int | Number of errors in the current iteration |
| recovered_from_error | bool | Whether the engine recovered from an error this iteration |

### States

| State | Description |
|-------|-------------|
| starting | Pipeline initializing (pre-flight checks, loading config) |
| running | Agent actively executing a phase |
| sleeping | Recoverable pause (quota backoff, rate limit throttle) -- check `sleep_until` for expected wake time |
| stalled | Unrecoverable failure or heartbeat timeout exceeded |
| completed | Pipeline hit max iterations or stall threshold |
| converged | Health score reached 100% |

### State Machine

```
starting -> running -> sleeping -> running (recovered)
                |           |
                |           +-> stalled (sleep expired, no wake)
                +-> stalled (3 consecutive failures)
                +-> completed / converged
```

### Observer Logic (Stall Detection)

External tools can detect stalls by reading engine-status.json and applying these rules:

1. **Read the file**: If engine-status.json is missing, the pipeline was never started (or the .gsd directory was cleaned up).
2. **Check the state field**:
   - `running` -- check heartbeat freshness (see below)
   - `sleeping` -- check if `sleep_until` is in the past (if yes, likely crashed during sleep)
   - `stalled` -- alert immediately; the engine has given up
   - `completed` / `converged` -- done; no action needed
3. **Heartbeat freshness** (when state is `running`):
   - Less than 2 minutes old: **ACTIVE** -- engine is running normally
   - 2-5 minutes old: **PROBABLY ACTIVE** -- agent may be in a long call
   - More than 5 minutes old: **LIKELY STALLED** -- engine may have crashed without updating state
4. **Optional PID verification**: Check if the `pid` value corresponds to a still-alive process for definitive crash detection.

### Heartbeat Interval

A background PowerShell job (`Start-EngineStatusHeartbeat`) updates `last_heartbeat` and `elapsed_minutes` every 60 seconds, independent of the main pipeline thread. This ensures the heartbeat stays fresh even during long-running agent calls (15-30+ minutes). The job is started when the pipeline starts and stopped in the `finally` block on exit.

## Specification Management

### Spec Consistency Pre-Check

Before starting a pipeline, the engine runs Invoke-SpecConsistencyCheck to detect contradictions in specification documents. Conflict types detected:

| Type | Description | Authoritative Source |
|------|-------------|---------------------|
| data_type | Conflicting type definitions | DB schema |
| api_contract | Mismatched API contracts | OpenAPI spec |
| navigation | Navigation/routing conflicts | Figma analysis |
| business_rule | Contradictory business logic | SDLC Phase B |
| design_system | Design token conflicts | Figma tokens |
| database | Schema contradictions | SDLC Phase D |
| missing_ref | Cross-reference gaps | Add cross-reference |

Critical conflicts block the pipeline and require human intervention or the -AutoResolve flag.

### Spec Conflict Auto-Resolution

With the -AutoResolve flag, the engine uses Gemini (`--yolo`) to automatically resolve spec contradictions, saving Claude/Codex quota for code generation. The resolution process:

1. Reads conflicts from .gsd/spec-conflicts/conflicts-to-resolve.json
2. Applies authoritative source priority (see table above)
3. Makes minimal edits to resolve each conflict (no full rewrites)
4. Max 2 resolution attempts per conflict
5. Writes results to .gsd/spec-conflicts/resolution-summary.md

### Storyboard Verification (Blueprint)

During blueprint verification, Claude traces data paths end-to-end:
- Component -> hook -> endpoint -> controller -> service -> stored procedure -> tables
- Validates structural links (method names, parameter matches)
- Checks state handling: loading, error, empty states
- Verifies mock data matches seed SQL

## Interface Detection

A complete project has three foundational layers:

```
UI Interfaces (web, mobile, mcp, browser, agent)
        |
    REST API / Backend (.NET Controllers -> Services -> Dapper)
        |
    Database (SQL Server stored procs -> tables -> seed data)
```

All UI interfaces communicate with the database through the API. The engine detects each layer as a separate interface.

The engine searches for design folders in this order:
1. Direct: {repo}\design\{type}\ (e.g., design\web\)
2. Recursive: searches up to 3 levels deep for any folder named {type} whose parent is "design"

Supported interface types: web, api, database, mcp, browser, mobile, agent

The `api` and `database` types can be detected two ways:
- **Design-dir based**: `design\api\v##` or `design\database\v##` (same as other types)
- **Auto-detected from project structure**: `.sln`/`.csproj` files trigger API detection; `database/`/`db/` directories containing `.sql` files trigger Database detection. Auto-detected interfaces are marked accordingly in the output.

Within each interface version folder, it recursively finds:
- _analysis/ (12 expected deliverable files from Figma Make)
- _stubs/ (backend controllers, DTOs, database scripts)

### Figma Make Deliverables (12 files)

| # | File | Content |
|---|------|---------|
| 01 | screen-inventory.md | All screens/pages |
| 02 | component-inventory.md | Reusable components |
| 03 | design-system.md | Colors, typography, spacing |
| 04 | navigation-routing.md | Routes and navigation flow |
| 05 | data-types.md | TypeScript interfaces |
| 06 | api-contracts.md | API endpoint definitions |
| 07 | hooks-state.md | React hooks and state management |
| 08 | mock-data-catalog.md | Development mock data |
| 09 | storyboards.md | User flow storyboards |
| 10 | screen-state-matrix.md | Loading/error/empty states per screen |
| 11 | api-to-sp-map.md | API endpoint to stored procedure mapping |
| 12 | implementation-guide.md | Build order and dependencies |

## File Map System

Generated by Update-FileMap function in resilience.ps1.

file-map.json contains:
- generated: timestamp
- repo_root: absolute path
- total_files, total_dirs, total_size_bytes
- extensions: per-extension counts and sizes
- directories: per-directory stats
- files: every file with path, dir, name, ext, size, modified

file-map-tree.md contains:
- File type summary sorted by count
- Directory tree with indentation
- Per-directory file counts and extension breakdown

Exclusions: node_modules, .git, bin, obj, packages, dist, build, .gsd, .vs, .vscode, TestResults, coverage

Injected into every agent prompt so they know where files are.

## Prompt Template System

### Template Resolution (Local-ResolvePrompt)

Before sending any prompt to an agent, the pipeline resolves template variables and appends context via `Local-ResolvePrompt`. This is a pipeline-internal function (not exported) that runs synchronously before every agent call.

### Template Variables

| Variable | Replaced With |
|----------|--------------|
| `{{ITERATION}}` | Current iteration number |
| `{{HEALTH}}` | Current health score percentage |
| `{{GSD_DIR}}` | Absolute path to .gsd directory |
| `{{REPO_ROOT}}` | Absolute path to repository root |
| `{{BATCH_SIZE}}` | Current batch size |
| `{{INTERFACE_CONTEXT}}` | Multi-interface summary (all detected interfaces, _analysis/ paths, _stubs/ paths) |

### Context Injection Order

Each resolved prompt is assembled in this order:

1. **Base prompt template** from `~/.gsd-global/prompts/{agent}/` with variables replaced
2. **File map** (`.gsd/file-map-tree.md`) appended for spatial awareness
3. **Interface context** injected via `{{INTERFACE_CONTEXT}}` variable
4. **Supervisor error context** (`.gsd/supervisor/error-context.md`) appended if present -- contains last iteration's errors and root cause
5. **Supervisor prompt hints** (`.gsd/supervisor/prompt-hints.md`) appended if present -- contains extra constraints from supervisor diagnosis

### Supervisor Prompt Modification

The supervisor modifies agent behavior by writing to two files that are auto-injected into all prompts:

- **error-context.md**: Written after each failed iteration. Contains the specific errors, root cause analysis, and instructions like "DO NOT use namespace X, use Y instead." Cleared when supervisor state is reset.
- **prompt-hints.md**: Written by `Invoke-SupervisorFix` based on AI diagnosis. Contains persistent constraints that survive across pipeline restarts within a supervisor cycle. Examples: "Always include TRY/CATCH in stored procedures", "Use explicit table aliases in all SQL joins."

Both files persist across pipeline restarts within a supervisor recovery cycle. They are only cleared when the supervisor state is manually reset or the issue is resolved.

### Prompt Templates by Agent

| Agent | Template Location | Phases |
|-------|------------------|--------|
| Claude | `~/.gsd-global/prompts/claude/` | review, plan, verify, blueprint, assess |
| Codex | `~/.gsd-global/prompts/codex/` | execute, build, research (fallback) |
| Gemini | `~/.gsd-global/prompts/gemini/` | research, spec-fix |

## Health Score System

### How Health Is Calculated

Health score represents the percentage of requirements that are satisfied. The score is computed during the review/verify phase by Claude, which reads the requirements matrix and source code to determine status.

| Requirement Status | Weight | Description |
|-------------------|--------|-------------|
| satisfied | 1.0 | Requirement fully implemented and verified |
| partial | 0.5 | Requirement partially implemented (code exists but incomplete) |
| not_started | 0.0 | No matching code found |
| blocked | 0.0 | Cannot proceed (dependency or spec issue) |

**Formula**: `health = (satisfied * 1.0 + partial * 0.5) / total_requirements * 100`

### Health Progression

Health is tracked over time in `health-history.jsonl` (one JSON line per iteration). The token cost calculator uses this data for historical progression analysis and the developer handoff report generates an ASCII bar chart from it.

### Stall Detection

The engine detects stalls when health does not improve for N consecutive iterations (configurable via `-StallThreshold`, default 3). When a stall is detected:

1. Pipeline exits with `exit_reason: "stalled"`
2. Supervisor (if enabled) reads `last-run-summary.json` and begins recovery
3. If supervisor is disabled (`-NoSupervisor`), pipeline exits and sends notification

### Regression Detection

After each iteration, `Test-HealthRegression` compares the new health score against the pre-iteration score. If health drops by more than 5%:

1. Git reverts to pre-iteration state (`git checkout` of changed files)
2. Stall counter increments
3. High-priority notification sent
4. Error logged to errors.jsonl with category `health_regression`

## Code Quality Validation

### SQL Validation

Pattern checks enforced on every iteration:
- No string concatenation in SQL (prevents SQL injection)
- TRY/CATCH required in all stored procedures
- Audit columns (CreatedAt, ModifiedAt) required in CREATE TABLE statements
- sqlcmd syntax validation when available

### Build Validation

- dotnet build with auto-fix capability (sends errors to Codex)
- npm run build with auto-fix capability
- Compilation error detection and structured logging

### CLI Version Validation

Pre-flight checks for required tools:

- claude (required)
- codex (required)
- gemini (required for partitioned review; falls back to codex for research/spec-fix if unavailable)
- dotnet (8.x)
- node, npm
- sqlcmd (optional)

Warns on untested versions but does not block execution.

## Quality Gates

Before final validation, the engine runs three quality gate checks that verify completeness, security, and spec quality.

### Pre-Generation: Spec Quality Gate

Runs once at pipeline start (before blueprint or convergence begins). Combines three checks:

| Check | Method | Token Cost | Action |
|-------|--------|-----------|--------|
| Spec consistency | `Invoke-SpecConsistencyCheck` | 0 (local) | Block on contradictions |
| Spec clarity | Claude via `spec-clarity-check.md` | ~$0.15 | Block if score < 70, warn 70-85 |
| Cross-artifact consistency | Claude via `cross-artifact-consistency.md` | ~$0.15 | Block on mismatches |

### Pre-Validation: Database Completeness

Runs before final validation when health reaches 100%. Zero token cost (regex scan).

Verifies the full chain: API Endpoint -> Stored Procedure -> Tables -> Seed Data.
- Scans `_analysis/11-api-to-sp-map.md` for the mapping table
- Falls back to scanning `[Http*]` attributes in `.cs` files
- Cross-references `CREATE PROC`, `CREATE TABLE`, `INSERT INTO` in `.sql` files
- Writes `.gsd/assessment/db-completeness.json`
- Failures injected into `supervisor/error-context.md` for next iteration

### Pre-Validation: Security Compliance

Runs before final validation. Zero token cost (regex scan of source files).

| Pattern | Severity | Description |
|---------|----------|-------------|
| String concat + SQL keywords | Critical | SQL injection |
| dangerouslySetInnerHTML (without DOMPurify) | Critical | XSS |
| eval() / new Function() | Critical | Code injection |
| localStorage + sensitive keywords | Critical | Secrets in browser storage |
| Hardcoded connection strings/passwords | Critical | Exposed credentials |
| Missing [Authorize] on controllers | High | Unprotected endpoints |
| Missing audit columns | Medium | CREATE TABLE without CreatedAt |

Critical violations are hard failures. High/medium are warnings.

### Enhanced Blueprint Tier Structure

| Tier | Name | Contents |
|------|------|----------|
| 1 | Database Foundation | Tables, migrations, indexes, constraints |
| 1.5 | Database Functions & Views | Views for complex reads, scalar/table-valued functions |
| 2 | Stored Procedures | All CRUD + business logic SPs |
| 2.5 | Seed Data | INSERT scripts per table group, FK-consistent, matching Figma mock data |
| 3 | API Layer | .NET 8 controllers, services, repositories, DTOs, validators |
| 4 | Frontend Components | React 18 components matching Figma exactly |
| 5 | Integration & Config | Routing, auth flows, middleware, DI, config files |
| 6 | Compliance & Polish | Audit logging, encryption, RBAC, error boundaries, accessibility |

## Final Validation Gate

When health reaches 100%, the engine runs a final validation gate before declaring CONVERGED or BLUEPRINT COMPLETE. This bridges the gap between "all requirements have matching code references" and "the code actually compiles and runs."

### Validation Checks

| # | Check | Command | Fail Type | Description |
|---|-------|---------|-----------|-------------|
| 1 | .NET build | `dotnet build --no-restore` | HARD | Compilation must succeed with zero errors |
| 2 | npm build | `npm run build` | HARD | Frontend must compile cleanly |
| 3 | .NET tests | `dotnet test --no-build` | HARD | All test projects must pass (if tests exist) |
| 4 | npm tests | `npm test` (with CI=true) | HARD | All tests must pass (if real test script exists) |
| 5 | SQL validation | `Test-SqlFiles` (existing function) | WARN | SQL pattern violations are advisory |
| 6 | .NET vulnerability audit | `dotnet list package --vulnerable` | WARN | Flags vulnerable NuGet packages |
| 7 | npm vulnerability audit | `npm audit --audit-level=high` | WARN | Flags high+ severity npm vulnerabilities |
| 8 | Database completeness | `Test-DatabaseCompleteness` | HARD | Full chain API->SP->Table->Seed verified |
| 9 | Security compliance | `Test-SecurityCompliance` | HARD/WARN | Critical=hard, High/Medium=warn |
| 10 | Seed data FK order | `Test-SeedDataFkOrder` | HARD | INSERT statements ordered to satisfy FK constraints |
| 11 | API endpoint discovery | `Find-ApiEndpoints` | -- | Discovers routes for smoke test (no pass/fail) |
| 12 | Runtime smoke test | `Invoke-ApiSmokeTest` | HARD | Starts app, hits endpoints, checks for HTTP 500s |

Checks 10-12 are added by the Runtime Smoke Test script (v2.1.0). See [Runtime Smoke Test](#runtime-smoke-test-patch-gsd-runtime-smoke-testps1) for details.

### Failure Handling

- **Hard failures** (checks 1-4, 8, 9-critical, 10, 12): Set health to 99%, write failures to `.gsd/supervisor/error-context.md` so the next iteration's code review picks them up, loop continues to fix the issues
- **Warnings** (checks 5-7, 9-high/medium): Included in the developer handoff report but do NOT block convergence
- **Max 3 validation attempts**: If validation fails 3 times, the pipeline exits to avoid infinite loops
- **Skipped checks**: If no .sln, no package.json, or no test projects exist, those checks are skipped (not a failure)

### Validation Retry Loop

The validation gate wraps the main iteration loop in an outer `do/while`:

```
do {
    while (health < target) { ... iterate ... }
    if (health >= 100%) {
        run final validation
        if (failed) { health = 99%, loop continues }
    }
} while (validation failed AND attempts < 3)
```

This allows the engine to automatically fix compilation errors, test failures, and build issues that only become apparent at 100% health.

### Output Files

| File | Purpose |
|------|---------|
| `.gsd/health/final-validation.json` | Structured results: passed/failed, hard failures, warnings, per-check details |
| `.gsd/logs/final-validation.log` | Human-readable log of all 7 checks |

## Developer Handoff Report

When the pipeline exits (converged, stalled, or max iterations), it automatically generates `developer-handoff.md` in the repository root. This gives the developer everything needed to pick up, compile, and run the project with minimal intervention.

### Report Sections

| # | Section | Content Source |
|---|---------|---------------|
| 1 | Header | Project name, pipeline, date, final health, iterations, exit reason |
| 2 | Quick Start | Auto-detected build commands (.sln → `dotnet restore && dotnet build`, package.json → `npm install && npm run build`, docker-compose → `docker-compose up`) |
| 3 | Database Setup | Recursively scanned .sql files (sorted by name), connection strings from appsettings.json |
| 4 | Environment Configuration | appsettings*.json files, .env files, placeholder value warnings |
| 5 | Project Structure | Content of `.gsd/file-map-tree.md` (truncated at 5000 chars) |
| 6 | Requirements Status | Table from requirements-matrix.json grouped by status (satisfied → partial → not_started) |
| 7 | Validation Results | From `Invoke-FinalValidation` output or "not run" if health < 100% |
| 8 | Known Issues | Remaining gaps from drift-report.md + last 10 entries from errors.jsonl |
| 9 | Health Progression | ASCII bar chart from health-history.jsonl showing iteration-by-iteration progress |
| 10 | Cost Summary | Total cost, breakdown by agent and phase from cost-summary.json |

### Generation Behavior

- Generated in the pipeline's `finally` block (always runs, even on crashes)
- Auto-committed and pushed to the remote repository
- Missing data files result in "Data not available" for that section (never crashes)
- Blueprint pipeline reads from `.gsd/blueprint/` paths; convergence from `.gsd/health/`

## Project Patterns (Enforced)

All pipelines enforce these patterns:
- **Backend**: .NET 8 + Dapper + SQL Server stored procedures only
- **Frontend**: React 18 functional components with hooks
- **API**: Contract-first, API-first
- **Compliance**: HIPAA, SOC 2, PCI, GDPR

## Global Configuration

Stored at %USERPROFILE%\.gsd-global\config\global-config.json:

```json
{
  "notifications": {
    "ntfy_topic": "auto",
    "notify_on": ["iteration_complete", "converged", "stalled", "quota_exhausted", "error"]
  },
  "patterns": {
    "backend": ".NET 8 with Dapper",
    "database": "SQL Server stored procedures only",
    "frontend": "React 18",
    "api": "Contract-first, API-first",
    "compliance": ["HIPAA", "SOC 2", "PCI", "GDPR"]
  },
  "phase_order": ["code-review", "create-phases", "research", "plan", "execute"],
  "council": {
    "enabled": true,
    "max_attempts": 2,
    "consensus_threshold": 0.66
  }
}
```

Set ntfy_topic to "auto" for per-project auto-detection, or a specific string to use one topic for all projects.

### LLM Council (Multi-Stage)

The LLM Council provides multi-agent cross-validation at 6 stages across both pipelines. Codex and Gemini review independently, then Claude synthesizes a consensus verdict. Claude is supervisor-only -- it does not participate in reviews.

#### Council Types

| Type | Trigger | Reviewers | Synthesizer | Action on Block |
|------|---------|-----------|-------------|-----------------|
| **convergence** | Health reaches 100% | Codex + Gemini | Claude | Health reset to 99%, feedback injected |
| **post-research** | After Gemini research phase | Codex + Gemini | Claude | Feedback injected into plan phase prompts |
| **pre-execute** | Before Codex execute phase | Codex + Gemini | Claude | Feedback injected into execute prompts |
| **post-blueprint** | After blueprint manifest generated | Codex + Gemini | Claude | Blueprint regenerated with feedback |
| **stall-diagnosis** | Health stalls (no progress) | Codex + Gemini | Claude | Root cause analysis replaces single-agent diagnosis |
| **post-spec-fix** | After Gemini resolves spec conflicts | Codex + Gemini | Claude | Retry spec resolution with feedback |

#### Agent Review Focus Areas

| Agent | Role | Focus Area |
|-------|------|-----------|
| Codex | Reviewer | Implementation completeness, error handling, stored procedure patterns, edge cases |
| Gemini | Reviewer | Requirements coverage, spec alignment, UI/UX flows, integration gaps |
| Claude | Synthesizer | Reads both reviews, finds consensus/disagreement, produces final verdict |

Non-blocking councils (post-research, pre-execute) inject feedback without stopping the pipeline. Blocking councils (convergence, post-blueprint) can force a retry.

#### Chunked Council Reviews

For projects with 30+ requirements, the convergence council automatically chunks requirements into smaller groups (default max 25 per chunk). This prevents quota exhaustion and ensures every requirement gets reviewed.

| Config | Default | Description |
|--------|---------|-------------|
| `chunking.enabled` | true | Enable/disable chunked reviews |
| `chunking.max_chunk_size` | 25 | Max requirements per chunk |
| `chunking.min_group_size` | 5 | Merge groups smaller than this |
| `chunking.strategy` | "auto" | "auto" (discover from data), "field:X" (explicit), "id-range" (sequential) |
| `chunking.cooldown_seconds` | 5 | Pause between chunks to avoid rate limits |
| `chunking.min_requirements_to_chunk` | 30 | Skip chunking for small projects |

The "auto" strategy reads the actual requirements-matrix.json and discovers the best grouping field dynamically (tries `pattern`, `sdlc_phase`, `priority`, `source`, `spec_doc`). No hardcoded domain maps.

#### Council Cost per Run

| Council Type | Reviewers | Est. Output Tokens | Est. Cost |
|-------------|-----------|-------------------|-----------|
| convergence (2+synthesis) | 2 | ~7,000 | ~$0.28 |
| convergence chunked (10 chunks) | 2 x 10 + 1 | ~3,000/chunk | ~$0.50-1.50 |
| post-research (2+synthesis) | 2 | ~5,000 | ~$0.12 |
| pre-execute (2+synthesis) | 2 | ~5,000 | ~$0.12 |
| post-blueprint (2+synthesis) | 2 | ~7,000 | ~$0.16 |
| stall-diagnosis (2+synthesis) | 2 | ~7,000 | ~$0.16 |
| post-spec-fix (2+synthesis) | 2 | ~5,000 | ~$0.12 |

Max 2 convergence council attempts per pipeline run. Findings are included in the developer handoff report.

## Token Cost Calculator

The engine includes a token cost calculator available as the `gsd-costs` command (installed globally by `install-gsd-global.ps1`). It estimates equivalent API costs for completing a project to 100%, even when using subscriptions. This enables accurate client billing and project cost forecasting.

### Dynamic Pricing

Pricing is fetched from the [LiteLLM open-source pricing database](https://github.com/BerriAI/litellm) on GitHub, a community-maintained JSON file with accurate per-token prices for all major providers. The calculator supports 6 models across 3 providers:

| Model | Input/1M | Output/1M | Used For |
|-------|----------|-----------|----------|
| Claude Sonnet 4.6 | $3.00 | $15.00 | Blueprint, verify (default) |
| Claude Opus 4.6 | $5.00 | $25.00 | Blueprint, verify (premium) |
| Claude Haiku 4.5 | $1.00 | $5.00 | Blueprint, verify (economy) |
| GPT 5.4 Codex | TBD | TBD | Code generation (build/execute) — default |
| GPT 5.3 Codex | $1.75 | $14.00 | Code generation (fallback) |
| GPT-5.1 Codex | $1.25 | $10.00 | Code generation (alternative) |
| Gemini 3 Pro | TBD | TBD | Research, spec-fix — default |
| Gemini 3.1 Pro Preview | $2.00 | $12.00 | Research, spec-fix (fallback) |

### Pricing Cache

Pricing is cached at `%USERPROFILE%\.gsd-global\pricing-cache.json` with three-tier freshness:

| Age | Behavior |
|-----|----------|
| < 14 days | Fresh -- used directly |
| 14-60 days | Aging -- auto-refresh attempted, falls back to cached |
| > 60 days | Stale -- warning displayed, auto-refresh attempted |

If all fetching fails, hardcoded fallback prices are used. The `-UpdatePricing` flag forces a fresh fetch.

### Cost Estimation Model

The calculator models token usage per pipeline phase:

**Blueprint pipeline (3-phase per iteration):**
- Blueprint (Claude, once) + Verify (Claude, per-iter) + Build (Codex, per-iter) + SpecFix (Gemini, ~15% of iters)

**Convergence pipeline (5-phase per iteration):**
- Blueprint (Claude, once) + Review + Research + Plan + Execute + Verify + SpecFix (~20% of iters)

Context scaling adjusts to project size:
- Blueprint context tokens: `min(100K, total_items * 200 + 5000)`
- File map tokens: `min(30K, total_items * 50)`
- Output per item varies by type (SQL migrations: 1K, controllers: 5K, components: 4K, etc.)

Iterations are estimated from: `ceil(effectiveRemaining / (batch * efficiency)) * (1 + retryRate)`

### Client Quoting

The `-ClientQuote` switch generates professional cost estimates with configurable markup (5-10x recommended):

- **Three-tier pricing**: Best case (0.6x markup), Expected (1x markup), Worst case (1.4x markup)
- **Complexity tiers**: Standard (≤100 items), Complex (≤250), Enterprise (≤500), Enterprise+ (>500)
- **Internal margin analysis**: Raw cost, markup, subscription offset, true profit/margin
- **Quote metadata**: Reference number, date, scope, timeline, inclusions, validity period

### Subscription vs API Comparison

The calculator always shows a subscription cost comparison, estimating project duration at ~3 iterations/day and computing the equivalent subscription cost ($60/mo minimum for Claude Pro + ChatGPT Plus + Gemini Advanced) vs. the calculated API cost.

## Token Cost Tracking

The engine tracks actual API token costs across all agent calls, persisting across aborts and restarts. This provides real cost data from first run to project completion and enables comparison against the token cost estimator.

### How It Works

All three CLIs are invoked with JSON output flags to capture token usage:
- **Claude**: `--output-format json` returns `total_cost_usd`, `result` text, `duration_ms`, `num_turns`
- **Codex**: `--json` returns JSONL with `turn.completed` events containing `usage.{input_tokens, output_tokens, cached_input_tokens}`
- **Gemini**: `--output-format json` returns `stats.{prompt_tokens, response_tokens, cached_tokens}`

Every agent call (including retries and fallbacks) is logged to `.gsd/costs/token-usage.jsonl` with a rolling summary maintained in `.gsd/costs/cost-summary.json`. If JSON parsing fails for any CLI call, the engine silently falls back to raw text output -- cost tracking never blocks the pipeline.

### Data Files

| File | Format | Purpose |
|------|--------|---------|
| `.gsd/costs/token-usage.jsonl` | Append-only JSONL | Ground truth: one line per agent call |
| `.gsd/costs/cost-summary.json` | JSON (rewritten) | Rolling totals by agent, phase, and run |

The JSONL file survives crashes (append-only). The summary file can always be rebuilt from JSONL if corrupted via `Rebuild-CostSummary`.

### Cost Data Per Agent Call

Each JSONL record captures:

| Field | Description |
|-------|-------------|
| timestamp | ISO 8601 timestamp |
| pipeline | "converge" or "blueprint" |
| iteration | Current iteration number |
| phase | Pipeline phase (e.g., "code-review", "execute") |
| agent | "claude", "codex", or "gemini" |
| batch_size | Number of items in the batch |
| success | Whether the call succeeded |
| is_fallback | Whether this was a fallback agent call |
| tokens | `{ input, output, cached }` token counts |
| cost_usd | Actual cost (from CLI or calculated from token counts) |
| duration_seconds | Wall-clock time for the call |
| num_turns | Number of agent turns (Claude only) |

### Estimated vs Actual Comparison

Run `gsd-costs -ShowActual` to see a side-by-side comparison of estimated and actual costs:

```
  ESTIMATED VS ACTUAL
  -----------------------------------------------
                    Estimated     Actual     Variance
  Total cost        $15.20       $12.45     -18.1%
  Claude            $8.50        $7.20      -15.3%
  Codex             $5.00        $3.90      -22.0%
  Gemini            $1.70        $1.35      -20.6%
```

### Safety Design

- All JSON parsing is wrapped in try/catch -- parse failure falls back to raw output
- `Save-TokenUsage` is wrapped in try/catch -- tracking failure never blocks the pipeline
- JSONL is append-only (survives crashes mid-write)
- Summary can be rebuilt from JSONL via `Rebuild-CostSummary` if corrupted
- Existing error detection (quota, rate limit, auth keywords) works on extracted text content

## v2.1.0 New Capabilities (Scripts 32-35)

### Runtime Smoke Test (patch-gsd-runtime-smoke-test.ps1)

Wraps the existing `Invoke-FinalValidation` to add checks 8-10 after the original 7 checks, closing the gap between "code compiles + tests pass" and "code actually runs without 500 errors."

| Function | Purpose |
|----------|---------|
| `Test-SeedDataFkOrder` | Static FK ordering scan of SQL seed files -- detects INSERT statements that would violate foreign key constraints due to ordering |
| `Find-ApiEndpoints` | Discovers API routes from controller files and OpenAPI specs |
| `Invoke-ApiSmokeTest` | Starts the application (`dotnet run`), waits for startup, hits discovered endpoints checking for HTTP 500 errors |
| `Invoke-RuntimeSmokeTest` | Orchestrator that runs all 3 checks |

The API smoke test detects three categories of runtime failure:
- **DI container errors**: `Cannot resolve scoped service` (lifetime mismatch)
- **FK constraint violations**: `SqlException: FK constraint` (seed data ordering)
- **General 500s**: Any HTTP 500 response from discovered endpoints

Prompt templates: `prompts/shared/health-endpoint.md`, `prompts/shared/di-service-lifetime.md`

Configuration in `global-config.json` under `runtime_smoke_test`:

| Key | Default | Description |
|-----|---------|-------------|
| `enabled` | true | Enable/disable runtime smoke testing |
| `startup_timeout_seconds` | 30 | Max wait for `dotnet run` to become responsive |
| `max_endpoints` | 50 | Cap on endpoints to probe per run |
| `block_on_500` | true | Whether 500 errors block convergence (reset health to 99%) |

### Partitioned Code Review (patch-gsd-partitioned-code-review.ps1)

Replaces single-agent Claude code review with 3-partition parallel review. Requirements are divided into three groups (A, B, C) and reviewed concurrently by different agents.

| Function | Purpose |
|----------|---------|
| `Split-RequirementsIntoPartitions` | Divides requirements into 3 groups (A, B, C) |
| `Get-SpecAndFigmaPaths` | Resolves spec documents and Figma deliverables for prompt context |
| `Invoke-PartitionedCodeReview` | Launches 3 parallel PowerShell jobs (one per partition) |
| `Merge-PartitionedReviews` | Combines 3 partition results into unified health score and review |
| `Update-CoverageMatrix` | Tracks which agent has reviewed which requirement across iterations |

**Rotation Matrix** (`iteration % 3` determines agent assignment):

| Iteration | Partition A | Partition B | Partition C |
|-----------|-------------|-------------|-------------|
| 1, 4, 7 | Claude | Gemini | Codex |
| 2, 5, 8 | Gemini | Codex | Claude |
| 3, 6, 9 | Codex | Claude | Gemini |

This ensures every agent reviews every partition over 3 iterations, eliminating single-agent blind spots.

**Partition Focus Areas** (3 prompt templates):
- **Partition A**: Implementation & Architecture
- **Partition B**: Data Flow & Integration
- **Partition C**: Security, Compliance & UX

Reviews validate against both spec documents and Figma deliverables.

**Agent Dispatch**: `Invoke-WithRetry` handles all three agents (claude, codex, gemini) with the `-GeminiMode` parameter controlling Gemini's approval mode. Prompts exceeding 8KB are automatically written to a temp file and piped via stdin to avoid shell argument-length limits. The patch script auto-patches `resilience.ps1` (step 2b) to add gemini dispatch if missing.

Configuration in `global-config.json` under `partitioned_code_review`:

| Key | Default | Description |
|-----|---------|-------------|
| `enabled` | true | Enable/disable partitioned review |
| `rotation_strategy` | "round-robin" | Agent rotation strategy |
| `validate_against_figma` | true | Include Figma deliverables in review context |
| `validate_against_spec` | true | Include spec documents in review context |

Output files:
- `.gsd/code-review/rotation-history.jsonl` -- append-only log of which agent reviewed which partition
- `.gsd/code-review/coverage-matrix.json` -- current coverage state across all requirements

Fallback: if partitioned review fails, falls back to single-agent Claude review.

### LOC-Cost Integration (patch-gsd-loc-cost-integration.ps1)

Connects LOC tracking with cost tracking and code review, providing cost-per-line metrics and injecting LOC context into agent prompts.

| Function | Purpose |
|----------|---------|
| `Save-LocBaseline` | Records starting commit hash for LOC delta calculation |
| `Complete-LocTracking` | Computes grand total LOC delta from baseline to HEAD |
| `Get-LocCostSummaryText` | Multi-line LOC vs Cost summary for final ntfy notifications |
| `Get-LocContextForReview` | LOC history table injected into code review prompts |
| `Get-LocNotificationText` | Enhanced to always include cost-per-line (e.g., "LOC: +250 / -30 net 220 | 12 files | $0.003/line") |

Integration points:
- **Code review prompts**: LOC context injected into standard, differential, and partitioned (A/B/C) review prompts so reviewers see how much code was generated
- **Template resolution**: `Local-ResolvePrompt` auto-injects LOC context for code-review phase
- **Final notifications**: CONVERGED/STALLED/MAX_ITERATIONS ntfy messages include grand total LOC vs cost summary

Uses the existing `loc_tracking` config block (no new configuration needed).

### Clarification System (v3/lib/modules/clarification-system.ps1)

Collects policy and design questions from generated code and agent output, consolidates them into a single `PIPELINE-CLARIFICATIONS.md` file in the repository root, and pauses the pipeline until answers are provided.

**Purpose**: When agents encounter ambiguous requirements — RBAC policies, auth providers, TODO markers, or incomplete business rules — they emit structured clarification requests instead of guessing. The clarification system aggregates these and presents them to the developer.

**Pipeline integration**: Pass `-ClarificationsFile "PIPELINE-CLARIFICATIONS.md"` to `gsd-full-pipeline.ps1` on the re-run to inject answers back into agent prompts.

**Pause behavior**: The pipeline exits cleanly at the end of the current phase with exit code 2 (distinct from error exit code 1). The `PIPELINE-CLARIFICATIONS.md` file contains all questions grouped by category (RBAC, Auth, Business Logic, Data Model). After editing the file with answers, re-run the pipeline with `-StartFrom {current-phase} -ClarificationsFile PIPELINE-CLARIFICATIONS.md`.

**Parameters** (`gsd-full-pipeline.ps1`):
- `-ClarificationsFile` — path to answered clarifications file (default: none)
- `-MaxPostConvIter` — max retry cycles per phase (default: 5)

### Runtime Fix Functions (V4 Auto-Fix Loop)

Phases 6, 7, and 8 of the full pipeline now retry up to `-MaxPostConvIter` times (default 5). Each retry invokes one or more auto-fix functions before re-running the failing phase:

| Function | Trigger | What It Fixes |
|----------|---------|---------------|
| `Invoke-RuntimeFix` | Backend fails to start (DI container errors) | Adds/corrects service registrations in `Program.cs` |
| `Invoke-EndpointFix` | Specific HTTP endpoints return 500 after startup | Fixes route handler implementation, missing SP calls |
| `Invoke-MiddlewareFix` | Middleware-order errors (e.g., auth before routing) | Reorders middleware pipeline in `Program.cs` to .NET 8 correct order |
| `Invoke-WireRouteInApp` | New screen components not reachable | Wires component into `App.tsx` router with correct path and lazy import |
| `Invoke-BackendCreate` | Missing C# module (controller/service/repository missing) | Generates full scaffold from spec for the missing module |
| `Invoke-SqlCreate` | Missing stored procedures for an endpoint | Generates T-SQL stored procedures from the API contract spec |

All fix functions are dispatched by `gsd-full-pipeline.ps1` automatically. They can also be invoked standalone for targeted repairs.

### Maintenance Mode (patch-gsd-maintenance-mode.ps1)

Adds post-launch maintenance capabilities for fixing bugs and adding features to already-converged projects.

**New Commands**:

| Command | Purpose |
|---------|---------|
| `gsd-fix` | Quick bug fix mode -- accepts bug descriptions, auto-creates BUG-xxx requirements, runs scoped convergence with reduced iterations |
| `gsd-update` | Incremental feature addition from updated specs (v02+), preserves satisfied requirements |

**New Parameters**:

| Parameter | Description |
|-----------|-------------|
| `--Scope` | Filters plan/execute to specific requirements while code-review still sees all (enables regression detection) |
| `--Incremental` | Additive Phase 0 that merges new requirements instead of rebuilding the matrix |

Prompt template: `prompts/claude/create-phases-incremental.md`

Configuration in `global-config.json` under `maintenance_mode`:

| Key | Description |
|-----|-------------|
| `fix_defaults` | Default settings for gsd-fix (max iterations, batch size) |
| `scope_filter` | Scope filtering behavior (plan/execute scoped, code-review unscoped) |
| `incremental_phases` | Settings for incremental requirement merging |

## Known Automation Boundaries

### Fully Automated (no human intervention)

- Agent CLI crash: retry with batch reduction
- Token/context limit hit: reduce batch, retry
- Rate limit (per-minute): sleep 2 min, retry
- Monthly quota exhausted: sleep hourly, test, up to 24h
- Network outage: poll 30s, resume when online
- Corrupt JSON output: restore from .last-good backup
- Disk full: auto-clean caches/bins/old logs
- Build compilation error: send to Codex for auto-fix
- SQL pattern violations: send to Codex for auto-fix
- Health regression >5%: auto-revert git to pre-iteration
- Concurrent run attempt: lock file blocks second instance
- Crash mid-iteration: checkpoint enables resume
- Agent crosses boundary: auto-revert unauthorized changes
- Stall (no progress): reduce batch, diagnose after threshold
- Spec contradictions (with -AutoResolve): Gemini auto-resolves via authoritative sources
- Pipeline stall/max iterations: supervisor root-causes via Claude, modifies prompts/specs/queue, restarts in new terminal (up to 5 attempts)
- Compilation errors at 100% health: final validation gate detects, resets to 99%, loop auto-fixes (up to 3 attempts)
- Test failures at 100% health: same as compilation errors -- auto-fix via validation retry loop
- Runtime 500 errors at 100% health: smoke test detects DI/FK/endpoint failures, resets to 99%, loop auto-fixes
- Developer handoff generation: auto-generated `developer-handoff.md` at pipeline exit with build commands, DB setup, requirements, costs
- Bug fixes via `gsd-fix`: auto-creates BUG-xxx requirements, runs scoped convergence
- Incremental feature addition via `gsd-update`: merges new requirements from updated specs

### Requires Human Intervention

- Contradictory specs without -AutoResolve (e.g., "use Dapper" vs "use EF")
- Figma .fig files unreadable (export to PNG/SVG/JSON, fill figma-mapping.md)
- Auth/API key expired (re-authenticate CLI or update keys via `setup-gsd-api-keys.ps1`)
- Fundamental architecture wrong (manual correction needed)
- Code compiles but logically wrong (review storyboards + unit tests)
- Quota exhausted for more than 24 hours (wait for billing cycle)
- CLI breaking changes (update scripts)
- Validation fails 3 times (compilation/test issues too complex for auto-fix)

## V3 Architecture Additions

The following sections document V3-specific architectural capabilities that extend the base engine described above.

### Multi-Model Execute Pool

The V3 pipeline distributes code generation across 7 models using a weighted round-robin strategy. This provides resilience against rate limits, cost optimization, and access to independent quota pools.

#### Pool Configuration

| Model | Provider | Weight | Selection Frequency |
|-------|----------|--------|-------------------|
| Codex Mini (gpt-5.1-codex-mini) | OpenAI | 3 | ~30% |
| DeepSeek Chat | DeepSeek | 2 | ~20% |
| Kimi (moonshot-v1-8k) | Moonshot AI | 1 | ~10% |
| MiniMax (MiniMax-Text-01) | MiniMax | 1 | ~10% |
| Claude Sonnet (claude-sonnet-4-6) | Anthropic | 1 | ~10% |
| Gemini Flash | Google | 1 | ~10% |
| GLM-5 (glm-4-flash) | Zhipu AI | 1 | ~10% |

#### How Rotation Works

1. Models are ordered by weight (highest first) and cycled through in round-robin fashion
2. When a model hits a rate limit, it is temporarily removed from the pool and the next model is selected
3. Models without configured API keys are excluded from the pool at startup
4. Higher-weight models handle more requests, concentrating work on the fastest and most reliable providers
5. The pool ensures that rate limits on any single provider never stall the pipeline

#### Cost Optimization

The weighting system naturally routes more work to cost-effective models (Codex Mini at $0.15/M input, DeepSeek at $0.14/M input) while keeping premium models (Claude Sonnet) available for complex requirements or when cheaper models are rate-limited.

### Anti-Plateau Protection

When the pipeline's health score stops improving, anti-plateau protection takes graduated action to break through stalls.

#### Detection Mechanism

The supervisor tracks consecutive zero-delta iterations (iterations where health score did not improve). Each iteration's health delta is recorded in `.gsd/health/health-history.jsonl`.

#### Graduated Escalation

| Zero-Delta Count | Level | Action |
|-----------------|-------|--------|
| 3 | Warning | Flag requirements that have failed 3+ times. Log warning to console and notifications. |
| 4 | Escalate | Recommend upgrading plan and review phases to Claude Opus for the top 3 stuck requirements. Maximum 10 Opus escalations per project. |
| 5 | Skip | Mark all stuck requirements as "deferred" in the requirements matrix. Remove them from the active pool. Continue pipeline with remaining requirements. |

#### Stuck Requirement Identification

A requirement is considered "stuck" if it appears in `.gsd/requirements/fail-tracker.json` with a fail count of 3 or more. The fail tracker is updated by the Verify phase each time a requirement fails verification.

#### Deferred Requirement Re-Check

Deferred requirements are not permanently abandoned. Every 10 iterations, the pipeline re-evaluates deferred requirements to check if their dependencies have been resolved or if the codebase has changed enough to unblock them.

### Spec Alignment Guard

The spec alignment guard is a mandatory pre-pipeline check that prevents the engine from generating code against outdated or mismatched specifications.

#### How It Works

1. **Pre-pipeline**: Before the first iteration, the guard compares specification documents in `docs/` and `design/` against the requirements matrix and existing codebase
2. **Periodic re-check**: Every 10 iterations, the guard re-runs to detect drift introduced by code changes
3. **Drift calculation**: Measures the percentage of requirements whose source specifications have changed or no longer match the codebase

#### Thresholds and Actions

| Drift Percentage | Severity | Action |
|-----------------|----------|--------|
| 0-5% | Normal | No action. Pipeline proceeds normally. |
| 5-20% | Moderate | Warning logged. Notification sent. Pipeline continues with caution. |
| >20% | Critical | Pipeline blocked. Must update specs or requirements before continuing. |

#### Contamination Prevention

The spec alignment guard was introduced after a contamination incident where the pipeline generated code matching an old spec version while new specs had been added to the repository. The guard ensures that specification documents, requirements, and codebase are all in agreement before any code generation begins.

### Multi-Frontend Parallel Pipelines

For repositories with multiple frontend frameworks (web, admin panel, mobile app, browser extension), the V3 pipeline can run per-interface pipelines in parallel.

#### Execution Order

```
Sequential: DATABASE --> BACKEND --> SHARED
Parallel:   WEB | MCP-ADMIN | BROWSER | MOBILE
```

1. **Sequential phases**: Database, backend, and shared code pipelines run sequentially because each depends on the previous layer
2. **Parallel phases**: Frontend pipelines run simultaneously (up to `max_parallel` concurrency) because they have no dependencies on each other
3. **Shared phases**: Cache warm, spec gate, and spec align run once and benefit all pipelines

#### Budget Proportioning

Total budget is split proportionally by requirement count per interface. Each pipeline tracks its own cost independently and halts when its allocation is exhausted without affecting other pipelines.

#### Health Aggregation

Overall project health is the weighted average of all interface health scores, where weights are proportional to requirement counts. Notifications include per-interface health breakdowns.

#### Failure Isolation

- Backend failure pauses all frontend pipelines (dependency)
- Frontend failure affects only that frontend; others continue
- Failed pipelines can be restarted independently using scope filters

## Existing Codebase Pipeline

### Architecture Overview

The Existing Codebase Pipeline (`gsd-existing.ps1`) is a specialized mode for repositories that already contain code and need verification against specifications. Unlike the standard convergence loop which assumes code needs to be generated, this pipeline front-loads verification to avoid regenerating existing work.

### Architecture Difference from Standard Pipeline

The standard pipeline follows a generate-then-verify loop:

```
[spec-gate] → [research] → [plan] → [execute] → [validate] → [review] → [verify] → loop
```

The existing codebase pipeline inverts this to verify-then-fill:

```
[spec-align] → [deep-extract] → [code-inventory] → [satisfaction-verify] → [targeted-execute] → [verify]
```

Key architectural distinctions:

| Component | Standard Pipeline | Existing Codebase Pipeline |
|-----------|------------------|---------------------------|
| Requirements source | Specs + existing matrix | Specs only (code is evidence, not source) |
| Iteration model | Multi-iteration convergence loop | Single pass with targeted execution |
| Execute scope | All unsatisfied requirements | Only verified gaps |
| Token budget | 4K-8K per phase | 16K with 32K auto-retry (large spec sets) |
| Cost profile | $50-400 over many iterations | $5-10 in a single pass |

### Data Flow

```
Spec Documents ──→ Deep Extract ──→ Requirements Matrix (from specs)
                                          │
Codebase ────────→ Code Inventory ──→ File-Capability Map
                                          │
                    Satisfaction Verify ◄──┘
                         │
              ┌──────────┴──────────┐
              │                     │
         [satisfied]          [gaps found]
              │                     │
         (no action)        Targeted Execute
                                    │
                               Final Verify
```

### Critical Design Decision: Requirements from Specs, Not Code

The pipeline extracts requirements exclusively from specification documents, never from existing code. Code is used only as evidence of satisfaction. This prevents a common failure mode where scanning code generates "requirements" that describe what was built rather than what should have been built, leading to false 100% satisfaction scores.

### Matrix Initialization

The deep-extract phase seeds the requirements matrix with a `requirements` array plus `total` and `summary` properties. All downstream phases use safe property access (`Add-Member` with existence checks) to prevent crashes on fresh or partially-initialized matrices.

## Full Pipeline Orchestrator

The Full Pipeline (`gsd-full-pipeline.ps1`) is the post-convergence quality gate that takes code from "converged" to "production-ready." As of V4, it runs 15 sequential phases covering convergence, security, API contracts, runtime validation, test generation, compliance, and deployment preparation.

### Full Pipeline Phases (V4)

The V4 pipeline expands the original 5-phase post-convergence pipeline to 15 phases. The 5 new phases are **securitygate**, **apicontract**, **testgeneration**, **compliancegate**, and **deployprep**.

```
convergence → databasesetup → buildgate → wireup → codereview
→ securitygate → buildverify → apicontract → runtime → smoketest
→ finalreview → testgeneration → compliancegate → deployprep → handoff
```

| # | Phase | Purpose | Output Files |
|---|-------|---------|-------------|
| 1 | convergence | Run gsd-converge until 100% health | `.gsd/health/`, requirements matrix |
| 2 | databasesetup | Apply SQL migrations, seed data, verify FK ordering | `.gsd/db/` |
| 3 | buildgate | dotnet build + npm run build must pass | `.gsd/build/` |
| 4 | wireup | Detect mock data, missing DI, unguarded routes | `.gsd/smoke-test/mock-data-scan.json`, `route-role-matrix.json` |
| 5 | codereview | 3-model consensus review (Claude + Codex + Gemini), auto-fix cycles | `.gsd/code-review/review-report.json`, `review-summary.md` |
| 6 | **securitygate** | SAST, secrets detection, dependency vulnerability scan, auth/crypto review | `.gsd/security-gate/security-gate-report.json`, `summary.md` |
| 7 | buildverify | Re-build after code review + security fixes | `.gsd/build/` |
| 8 | **apicontract** | Extract OpenAPI spec from running backend, detect breaking changes, verify frontend alignment | `.gsd/api-contract/openapi.json`, `api-contract-report.json`, `summary.md` |
| 9 | runtime | Start app, hit all endpoints, check for HTTP 500s and DI errors | `.gsd/health/final-validation.json` |
| 10 | smoketest | 9-phase integration validation (build, DB, API, routes, auth, modules, mock data, RBAC, gap report) | `.gsd/smoke-test/smoke-test-report.json`, `gap-report.md` |
| 11 | finalreview | Post-smoke-test re-review at lower severity threshold | `.gsd/code-review/final-review-report.json` |
| 12 | **testgeneration** | Generate xUnit, Jest/RTL, and Playwright E2E tests; execute with fix loop | `.gsd/test-generation/test-generation-report.json` |
| 13 | **compliancegate** | HIPAA, PCI DSS, GDPR, SOC 2 enforcement | `.gsd/compliance-gate/compliance-gate-report.json`, `summary.md` |
| 14 | **deployprep** | Generate Dockerfile, docker-compose, CI/CD workflows, env configs, nginx | Deployment files in repo root + `.gsd/deploy-prep/deploy-prep-report.json` |
| 15 | handoff | Generate PIPELINE-HANDOFF.md + developer-handoff.md | `PIPELINE-HANDOFF.md`, `developer-handoff.md` |

Phases 6, 7, 8, 12, 13, and 14 are new in V4. Each can be individually skipped via `-Skip*` parameters. The pipeline is resumable via `-StartFrom` and logs to `~/.gsd-global/logs/{repo}/full-pipeline-{timestamp}.log`.

### Phase Architecture (V4 additions)

New phases in the V4 pipeline:

| Phase | Purpose | Tools |
|-------|---------|-------|
| Security Gate | SAST scanning, hardcoded secret detection, NuGet/npm vulnerability audit, auth flow review, crypto review | gsd-security-gate.ps1 |
| API Contract | OpenAPI spec extraction from running backend (or source code fallback), breaking-change detection, TypeScript client generation | gsd-api-contract.ps1 |
| Test Generation | xUnit unit test generation, Jest/RTL frontend tests, Playwright E2E tests; execute with 3-cycle fix loop | gsd-test-generation.ps1 |
| Compliance Gate | HIPAA, PCI DSS, GDPR, SOC 2 rule enforcement; evidence report generation | gsd-compliance-gate.ps1 |
| Deploy Prep | Dockerfile + Dockerfile.frontend, docker-compose.yml, GitHub Actions CI/CD, nginx.conf, appsettings per-env, .env.example | gsd-deploy-prep.ps1 |

Original phases retained:

| Phase | Purpose | Tools |
|-------|---------|-------|
| Wire-Up | Detect integration gaps (mock data, missing DI, unguarded routes) | mock-data-detector.ps1, route-role-matrix.ps1 |
| Code Review | 3-model consensus review (Claude + Codex + Gemini) with auto-fix | gsd-codereview.ps1 |
| Smoke Test | 9-phase integration validation with tiered cost optimization | gsd-smoketest.ps1 |
| Final Review | Post-smoke-test re-review at lower severity threshold | gsd-codereview.ps1 |
| Handoff | Generate PIPELINE-HANDOFF.md with all results | Built-in |

The pipeline is resumable via `-StartFrom` parameter and logs to `~/.gsd-global/logs/{repo}/full-pipeline-{timestamp}.log`.

## Smoke Testing (9-Phase Integration Validation)

The smoke test (`gsd-smoketest.ps1`) verifies runtime integration through 9 phases:

| Phase | Tier | Cost | Validates |
|-------|------|------|-----------|
| Build Validation | LOCAL | $0 | dotnet build + npm run build |
| Database Validation | CHEAP | ~$0.05 | Tables, SPs, FKs, migrations |
| API Smoke Test | MID | ~$0.10 | Controllers, middleware, DI, CORS |
| Frontend Routes | LOCAL | $0 | Route-component mapping, lazy loads |
| Auth Flow | MID | ~$0.10 | JWT/Azure AD, guards, token refresh |
| Module Completeness | CHEAP | ~$0.05 | API + frontend + DB per module |
| Mock Data Detection | LOCAL | $0 | Hardcoded data, TODOs, placeholders |
| RBAC Matrix | LOCAL | $0 | Route → role → guard mapping |
| Integration Gap Report | PREMIUM | ~$0.50 | Aggregated analysis + fix recommendations |

Total cost per run: ~$0.50-1.00 with tiered optimization (vs $5-8 without).

### Tiered LLM Cost Optimization

Four tiers route each task to the cheapest suitable model:

| Tier | Models | Cost/1M Tokens | Tasks |
|------|--------|---------------|-------|
| LOCAL | None | $0 | Build, route parsing, RBAC matrix, mock data scan |
| CHEAP | DeepSeek, Kimi, MiniMax | $0.14-0.21 | DB schema, module completeness, config validation |
| MID | Codex Mini | $1.50 | API wiring, auth flow, DI registration |
| PREMIUM | Claude Sonnet | $9.00 | Security review, gap report, fix generation |

Fallback chain: CHEAP models fall back to MID tier if all cheap models fail.

## Wire-Up Phase (Integration Gap Prevention)

Detects integration gaps that code review cannot catch:

- **Mock Data Detector**: Scans for 12 patterns (hardcoded useState, mock constants, TODO/FIXME, placeholder URLs, fake credentials, mock imports, Promise.resolve stubs)
- **Route-Role Matrix**: Maps every route → role → guard. Identifies unguarded routes, orphan navigation, unused roles, missing config files
- **Backend Wiring**: Controllers discoverable, services in DI, connection strings real, auth middleware ordered, CORS configured
- **Frontend Wiring**: Pages routed in App.tsx, API base URL from env, auth provider wraps app, protected routes guarded
- **Database Wiring**: Connection strings match real DB, stored procedures exist, parameter names/types match
- **Auth Wiring**: Real Azure AD/JWT values, MSAL configured, token refresh exists, logout clears tokens

## 3-Model Code Review

The code review (`gsd-codereview.ps1`) uses 3-model consensus:

1. Claude, Codex, and Gemini review the same requirements independently
2. Issues found by 2+ models receive higher confidence
3. Fix model (Claude by default) generates corrections for critical/high issues
4. Re-review after fixes until clean or MaxCycles (5) reached

Output: `.gsd/code-review/review-report.json` + `review-summary.md`

## LLM Pre-Validate Fix Phase

The validation fixer (`gsd-validation-fixer.ps1`) runs before local build to proactively fix errors:

1. Quick namespace fixes (60+ regex patterns, zero LLM cost)
2. Sonnet reviews recently generated files in batches of 5
3. Multi-file grouping for cross-file fixes
4. Local build runs as confirmation, not discovery

## Centralized Logging

All pipeline runs write to `~/.gsd-global/logs/{repo-name}/`:

- **Per-run logs**: `run-{timestamp}.log` + `.json` metadata
- **Per-iteration metrics**: `iterations/iter-NNNN.json` with health, cost, duration, batch info
- **Persistent iteration counter**: `iteration-counter.json` survives pipeline restarts
- **Tool-specific logs**: `smoketest-{ts}.log`, `codereview-{ts}.log`, `full-pipeline-{ts}.log`
- **Supervision insights**: `~/.gsd-global/logs/supervision-insights.md` for cross-session learning

---

## Verification Gates (Post-Delivery Checklist)

Three classes of defect escape code review because they are runtime-only, not statically detectable. These gates must be applied before any developer handoff is accepted as complete.

### Gate 1 — CSS Responsive Utility Verification

**What it catches**: Tailwind v4 pre-built `index.css` files can be generated or committed without `@media` blocks for responsive utilities. The desktop sidebar uses `md:flex` to become visible at ≥768px — if that class is absent the sidebar remains `display:none` for all roles. Code review cannot detect this because TypeScript compiles fine regardless of what is in the CSS file.

**Check**:
```bash
grep -c "md:flex" src/Client/technijian-spa/src/index.css
# Must be > 0. Rebuilt files are typically 4800+ lines with 170+ @media blocks.
```

**Fix if failing** (Tailwind v4 rebuild):
```bash
npm install -D @tailwindcss/cli@4.1.3 tailwindcss@4.1.3
echo '@import "tailwindcss";' > src/tailwind-input.css
npx @tailwindcss/cli@4.1.3 -i src/tailwind-input.css -o src/index.css
```

Commit both `tailwind-input.css` and the rebuilt `index.css`.

### Gate 2 — Database Migration Completeness

**What it catches**: The pipeline writes stored procedures and C# code that reference tables by name, but if no migration creates those tables the runtime throws SQL errors while TypeScript and dotnet build both succeed. This is a silent gap — requirements are marked satisfied when code compiles, but the feature fails when executed.

**Check**: For every stored procedure, every table it references must have a `CREATE TABLE` in a migration file:
```bash
grep -r "CREATE TABLE Modules" Database/Migrations/    # must return a result
grep -r "CREATE TABLE Roles"   Database/Migrations/
grep -r "CREATE TABLE RoleModules" Database/Migrations/
```

If any table has no migration: mark requirement `BLOCKED`, reason `"missing migration for {table}"`. Do not promote to `satisfied` until migration is written and verified.

**Add to code-review checklist**: "For every stored procedure in this diff: does a migration CREATE every table it references?"

### Gate 3 — Headless UI Smoke Test (E2E render gate)

**What it catches**: The first two gates are static checks. This gate runs the actual browser to confirm the app renders for each role. It catches runtime issues — missing providers, context errors, invisible sidebars, auth redirects — that no amount of static analysis finds.

**Run before any handoff**:
```bash
cd src/Client/technijian-spa
npx playwright test --config=playwright.e2e.config.ts e2e/navigation.spec.ts e2e/screens.spec.ts
```

A passing run (0 failures, all roles render sidebar with correct links) is the handoff gate. If any test fails, treat it as a P1 bug, not a test issue.

**Minimum smoke spec** (if full E2E suite doesn't exist yet):
```typescript
// e2e/smoke.spec.ts
for (const role of ['technijian_admin', 'technijian_employee', 'client_admin', 'client_user']) {
  test(`${role} sees sidebar`, async ({ page, context }) => {
    await setupRole(context, role);
    await page.goto('/chat');
    await waitForAppReady(page);
    const sidebar = page.locator('aside[aria-label="Main navigation"]');
    await expect(sidebar).toBeVisible({ timeout: 8000 });
  });
}
```

---

## E2E Test Infrastructure

### Auth Bypass Pattern

MSAL/Azure AD authentication cannot run in headless Playwright tests. The bypass pattern skips the auth provider entirely and reads the test role from `sessionStorage`.

**Environment flag**: `VITE_E2E_BYPASS_AUTH=true` (set in `.env.test` and in `playwright.e2e.config.ts` `webServer.env`)

**Implementation**:
- `main.tsx`: when flag is true, render without `MsalProvider` and skip `initializeMsal()`
- `AuthContext.tsx`: in `useEffect`, if flag is true read `sessionStorage.getItem('e2e_test_role')` and set all auth state synchronously, then `setIsLoading(false)`

**Test setup** (`e2e/helpers.ts`):
```typescript
await context.addInitScript((role) => {
  sessionStorage.setItem('e2e_test_role', role);
  sessionStorage.setItem('tcai.tenantId', 'test-tenant-id');
}, role);
```

This pattern keeps E2E auth bypass 100% isolated from production — the flag is never true in non-test Vite modes.

### Playwright Route Mock Ordering (Critical)

**Playwright uses LIFO order** — the last-registered `context.route()` handler has the highest priority and is tried first.

**The bug**: If a catch-all `${origin}/api/**` route is registered _after_ specific routes (e.g. `/navigation/my-modules`), the catch-all intercepts every request first and returns `[]` before the specific handler can run. The result is HTTP 200 with empty data — silent failure. In practice this caused `modules = []` → `isModuleUrlAllowed()` always false → "Access Forbidden" on every module-guarded route for all roles.

**The rule**: Always register catch-all routes **first** (lowest priority), specific routes **last** (highest priority):
```typescript
// helpers.ts — CORRECT order
// Step 1: catch-all (lowest priority — registered first)
for (const origin of apiOrigins) {
  await context.route(`${origin}/api/**`, (route) => {
    route.fulfill({ status: 200, body: method === 'GET' ? '[]' : '{}' });
  });
}
// Step 2: specific routes (highest priority — registered last)
for (const pattern of routeApiPattern('/navigation/my-modules')) {
  await context.route(pattern, (route) => {
    route.fulfill({ status: 200, body: JSON.stringify(modules) });
  });
}
```

### Standard E2E File Structure

```
e2e/
├── helpers.ts          # setupRole(), waitForAppReady(), getVisibleNavItems()
├── mock-data.ts        # MODULES_BY_ROLE for all roles, MOCK_TENANT, mockProfile()
├── navigation.spec.ts  # Sidebar visibility, nav links, role-specific access (22 tests)
├── screens.spec.ts     # Screen render + access control for all roles (50 tests)
└── debug.spec.ts       # Screenshot + state capture utility (not in CI)
```

```
playwright.e2e.config.ts  # Port 3001, mode=test, reuseExistingServer=false
.env.test                 # VITE_E2E_BYPASS_AUTH=true, VITE_API_BASE_URL=http://localhost:60112/api
```

### Navigation Module Mock Data

Mock data must mirror the database seed exactly (same IDs, same URLs, same parentIds):

| Role | Modules |
|------|---------|
| technijian_admin | All modules |
| technijian_employee | All except Revenue, Subscription Plans, User Assignments |
| client_admin | Chat, Assistants, MyGPTs, Projects, Files, Council, subset of Admin, Settings, Help |
| client_user | Chat, Assistants, Projects, Files, Help, Settings, Settings/Billing |

---

## Memory System — Learned Patterns

The GSD engine maintains a persistent memory of cross-session learnings in `~/.claude/projects/{project}/memory/`. These are facts that are non-obvious, painful to rediscover, and worth front-loading into every session.

### Saved Patterns (as of 2026-03-31)

| Memory File | What It Records |
|-------------|----------------|
| `feedback_playwright_lifo_routing.md` | Playwright LIFO route priority — catch-all must be registered first |
| `feedback_tailwind_v4_css_verification.md` | Tailwind v4 pre-built CSS can be missing responsive utilities — always verify `md:flex` |
| `feedback_db_migration_completeness.md` | Tables referenced in stored procs must have CREATE TABLE migrations — verify before marking satisfied |
| `feedback_proactive_monitoring.md` | Stop passive monitoring — actively fix root causes every tick |
| `feedback_spec_alignment_guard.md` | Always verify requirements match specs before pipeline runs |
| `feedback_codereview_optimizations.md` | Claude fixer (not Codex), parallel review, early-stop, skip clean reqs |
| `pipeline-patterns.md` | 10 recurring disease patterns: truncation, decomp spiral, validation waste, etc. |

### How Memories Are Applied

1. On session start, Claude Code reads `MEMORY.md` index (always in context)
2. Relevant memory files are fetched on-demand when topics match
3. Before any Playwright test setup — check `feedback_playwright_lifo_routing.md`
4. Before accepting any CSS change — check `feedback_tailwind_v4_css_verification.md`
5. Before marking DB requirements satisfied — check `feedback_db_migration_completeness.md`

---

## Obsidian Knowledge System (Bidirectional Vault Integration)

The pipeline maintains a persistent knowledge base in an Obsidian vault at `D:\obsidian\gsd-autonomous-dev\gsd-autonomous-dev\`. This is a **bidirectional** system — the pipeline both reads from and writes to the vault, so it learns from past mistakes and applies that knowledge on every iteration.

### Vault Structure

```
02-Projects/{project}/index.md   — health history, schema notes, session logs per project
03-Patterns/diseases/            — recurring failure patterns with status + first_seen
03-Patterns/solutions/           — validated fixes with reproduction steps
05-Architecture/                 — ADRs, system design diagrams
06-Sessions/                     — per-iteration notes written automatically by write-vault-note.ps1
07-Feedback/                     — standing rules from mistakes (requirements-source, code-review, etc.)
Welcome.md                       — Dataview dashboard: active projects, open diseases, recent feedback
```

### Knowledge Flow

```
Pipeline Phase → read-vault-context.ps1 → {{VAULT_KNOWLEDGE}} → LLM Prompt
                                                                      ↓
                                                             Phase Output (JSON)
                                                                      ↓
                                                    Issue found? → write-vault-lesson.ps1
                                                                      ↓
                                                             Obsidian Vault Updated
```

### Reading: `read-vault-context.ps1`

Called at the start of each phase. Reads phase-relevant vault content and injects it as `{{VAULT_KNOWLEDGE}}` into the LLM prompt.

```powershell
& read-vault-context.ps1 -VaultRoot "D:\obsidian\..." -Project "chatai-v8" -Phase "plan" -MaxTokens 2000
```

**What it reads per phase**:
- **plan**: All open diseases + solutions relevant to current interface + project schema notes + feedback rules
- **review**: Auth-wiring solutions, mock-data diseases, SP-existence rules
- **verify**: DB verification rules, TypeScript noise classification, integration completeness patterns
- **spec-gate**: Spec drift incidents, requirements-source rules

### Writing: `write-vault-lesson.ps1`

Called automatically when the pipeline detects a noteworthy event. Creates or updates Obsidian notes mid-pipeline.

```powershell
& write-vault-lesson.ps1 -Type lesson -Project chatai-v8 -Phase review `
  -Title "Auth context lost after TCAIApp.tsx replacement" `
  -Body "..." -Severity high
```

**Automatically triggered by**:
- Review phase: `critical_issue` findings → `07-Feedback/{project}-{title}.md`
- Verify phase: SP referenced in code but not confirmed in DB → disease note
- Spec-gate: conflicts detected with blocking severity → spec-drift incident note
- Full pipeline: mock-data scan finds >5 gaps → `03-Patterns/diseases/mock-data-not-wired.md`

**Types written**:

| Type | Vault Location | Purpose |
|------|---------------|---------|
| `lesson` | `07-Feedback/` | Standing rules from mistakes |
| `disease` | `03-Patterns/diseases/` | Recurring failure patterns |
| `solution` | `03-Patterns/solutions/` | Validated fixes |
| `schema` | `02-Projects/{project}/index.md` | DB schema surprises |
| `feedback` | `07-Feedback/` | Positive confirmations |
| `mistake` | `07-Feedback/` | Critical errors to avoid |

### Phases with Vault Integration

| Phase | Prompt File | Vault Injected | Auto-Writes |
|-------|-------------|----------------|-------------|
| Spec Gate | `01-spec-gate-incremental.md` | Yes | Spec drift incidents |
| Plan | `03-plan.md` | Yes | — |
| Review | `06-review.md` | Yes | Critical issues as lessons |
| Verify | `07-verify.md` | Yes | SP existence gaps as diseases |

### Key Rules Encoded in Prompts (from Vault)

**DB Verification Rule** (in verify prompt):
- SP referenced in C# but not confirmed in DB → `partial`, not `satisfied`
- SP file in repo = written, not necessarily deployed

**TypeScript Noise Classification** (in verify prompt):
- TS6133/TS6196/TS6192/TS6198 (unused vars) = **noise** — do NOT block satisfaction
- TS2307/TS2339/TS2345/TS2304 = **real errors** — block satisfaction

**Design Source Detection** (in plan prompt):
- Before planning ANY frontend screen: check if `design/web/v{N}/src/` exists
- If yes: plan is "copy + wire to real API" — never regenerate from scratch

**Auth Wiring Check** (in review prompt):
- Any modification to `App.tsx`, `TCAIApp.tsx`, or root/layout components must preserve AuthContext imports
- `useState('admin')` hardcoded in root = critical auth bypass

### Mock-to-DB Gap Detection

`scripts/detect-mock-to-db-gaps.ps1` audits the frontend for mock data that hasn't been wired to the database. Run before starting a feature_update pipeline to surface gaps automatically.

```powershell
& detect-mock-to-db-gaps.ps1 -RepoRoot "D:\vscode\myapp\myapp" -ProjectSlug "myapp"
```

**What it does**:
1. Scans all `.ts`/`.tsx` files for mock data patterns (`mockX`, `fakeX`, hardcoded arrays, `Promise.resolve(staticData)`)
2. Derives entity names (e.g., `mockUsers` → entity `User`)
3. Checks if a matching DB table, stored procedure, controller, and service exist
4. Generates `AUTO-MOCK-NNN` requirement templates for gaps
5. Saves report to `.gsd/mock-gap-report.json`

**Output format**:
```json
{
  "gaps": [
    {
      "id": "AUTO-MOCK-001",
      "entity": "Notification",
      "mock_file": "src/hooks/useNotifications.ts",
      "missing": ["db_table", "stored_procedure", "controller"],
      "requirement_template": "Wire useNotifications hook to real DB: seed data → SP → controller → hook"
    }
  ]
}
```
