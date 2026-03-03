# GSD Engine Architecture

## Overview

The GSD Engine orchestrates three AI agents (Claude Code, Codex CLI, and Gemini CLI) through PowerShell scripts to autonomously develop, fix, and verify code against specifications. It runs unattended with comprehensive self-healing for network failures, quota limits, disk space, JSON corruption, agent boundary violations, and stalls.

The three-model strategy distributes work across independent quota pools: Claude handles reasoning (review, plan, verify), Codex handles code generation (execute), and Gemini handles research and spec-fix (saves Claude/Codex quota).

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
  config\
    global-config.json          # Global settings (notifications, patterns, phases)
  lib\modules\
    resilience.ps1              # Retry, checkpoint, lock, rollback, adaptive batch, hardening
    interfaces.ps1              # Multi-interface detection + auto-discovery
    interface-wrapper.ps1       # Context builder for agent prompts
  prompts\
    claude\                     # Claude Code prompt templates (review, plan, verify)
    codex\                      # Codex prompt templates (execute, research fallback)
    gemini\                     # Gemini prompt templates (research, spec-fix)
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
  logs\
    errors.jsonl                # Categorized errors (JSONL)
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
```

## Data Flow

### gsd-assess

1. Detect interfaces (recursive scan for design\{type}\v##)
2. Auto-discover _analysis/ and _stubs/ within each interface
3. Generate file map (JSON + tree)
4. Send assessment prompt to Claude with file map + interface context
5. Claude produces work classification and inventories

### gsd-converge (per iteration)

1. PRE-FLIGHT: CLI version check, network test, disk space, spec consistency
2. REVIEW: Claude reviews code, identifies issues, scores health
3. RESEARCH: Gemini (plan mode, read-only) researches patterns; falls back to Codex if unavailable
4. PLAN: Claude creates fix plan with prioritized batch
5. EXECUTE: Codex makes code changes
6. VERIFY: Claude re-scores health, commits if improved
7. POST-ITERATION: File map update, checkpoint save, notification

### gsd-blueprint

1. PRE-FLIGHT: CLI version check, network test, disk space, spec consistency
2. GENERATE: Claude creates blueprint manifest from _analysis/ specs
3. BUILD: Codex generates code for each blueprint item (adaptive batch)
4. VERIFY: Claude verifies against specs with storyboard tracing, scores health
5. Repeat until 100% or stalled

## Agent Assignment (Three-Model Strategy)

| Phase | Agent | Mode | Why |
|-------|-------|------|-----|
| Review | Claude | `--allowedTools Read,Write,Bash` | Better at architectural analysis |
| Research | **Gemini** | `--approval-mode plan` (read-only) | Saves Claude/Codex quota; falls back to Codex |
| Plan | Claude | `--allowedTools Read,Write,Bash` | Better at strategic planning |
| Execute | Codex | `--full-auto` | Faster at bulk code generation |
| Verify | Claude | `--allowedTools Read,Write,Bash` | Better at spec compliance checking |
| Spec-Fix | **Gemini** | `--yolo` (write) | Saves Claude/Codex quota for code gen |
| Blueprint | Claude | `--allowedTools Read,Write,Bash` | Better at spec-to-manifest generation |
| Build | Codex | `--full-auto` | Faster at code generation from specs |

Token budgets are optimized across three independent quota pools:
- Claude Code: 4 reasoning phases (review, create-phases, plan, verify) = ~5K tokens each
- Codex: 1 execution phase (execute) = ~65K tokens per iteration
- Gemini: 2 supporting phases (research, spec-fix) = ~10K tokens per iteration

### Why Three Models?

Each agent draws from an independent API quota pool. This means:
- Claude quota exhaustion does NOT block Gemini research or Codex execution
- Codex quota exhaustion does NOT block Claude review or Gemini research
- Gemini handles the "unlimited reading" work that previously burned through Codex quota
- Overall throughput increases because agents can work without competing for the same quota

### API Key Authentication

Each agent CLI supports two authentication methods: interactive login (OAuth) and API key environment variables. API keys bypass interactive rate limits and enable higher throughput for autonomous pipelines.

| Environment Variable | CLI | Expected Prefix | Purpose |
|---------------------|-----|----------------|---------|
| ANTHROPIC_API_KEY | Claude Code | sk-ant- | Review, plan, verify, blueprint phases |
| OPENAI_API_KEY | Codex | sk- | Execute, build phases |
| GOOGLE_API_KEY | Gemini | AIza | Research, spec-fix phases |

API keys are configured during installation (Step 0 of `install-gsd-global.ps1`) or via the standalone `setup-gsd-api-keys.ps1` script. Keys are stored as persistent User-level environment variables (Windows registry), never committed to git.

If API keys are not set, agents fall back to interactive OAuth authentication (which may have lower rate limits).

### Gemini Fallback

If the Gemini CLI (`gemini`) is not installed, the engine automatically falls back to Codex for research and spec-fix phases. Install Gemini CLI to get the full benefit of three-model optimization:

```
npm install -g @google/gemini-cli
gemini    # first run authenticates
```

## Resilience Features

### Retry with Batch Reduction

Failed agent calls retry 3 times. Each retry halves the batch size (15 -> 7 -> 3 -> 1). Minimum batch is 1.

### Checkpoint Recovery

After each successful phase, state is saved to .gsd-checkpoint.json. On restart, the engine resumes from the last checkpoint. Stores pipeline, iteration number, phase, health score, batch size, status, and process ID.

### Lock File

.gsd-lock prevents concurrent GSD runs in the same repo. Lock includes timestamp for stale detection (auto-cleared after 120 min).

### Quota Management

Detects "quota exhausted" or "rate limit" in agent output. Adaptive backoff: starts at 5 minutes, doubles each cycle (5 -> 10 -> 20 -> 40 -> 60 -> 60 min cap). Max 24 hours of retries with hourly quota checks. Differentiates rate_limit (wait 2 min) vs quota_exhausted (wait hours).

### Proactive Throttling

Adds configurable delays between agent calls to prevent hitting quota limits during long runs. Default: 30 seconds between phases. Configurable via -ThrottleSeconds parameter on both gsd-converge and gsd-blueprint.

### Network Polling

Tests network by running: claude -p "PING" --max-turns 1

Polls every 30 seconds when offline. Resumes when connectivity returns. Max wait: 1 hour.

### Git Snapshots

Creates git snapshot before any destructive operation. Auto-commits after each successful iteration with message: gsd: iter N (health: X%)

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

All errors logged to .gsd/logs/errors.jsonl with categories: quota, network, disk, corrupt_json, boundary_violation, agent_crash, health_regression, spec_conflict, watchdog_timeout. Each entry includes timestamp, phase, iteration, message, and resolution.

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
| Heartbeat | "Working: {phase}" | low | hourglass_flowing_sand |
| Agent timeout | "Agent Timeout: {agent}" | high | skull |
| Iteration complete | "Iter N Complete" / "Blueprint Iter N" | default | chart_with_upwards_trend |
| No progress (stall) | "Iter N: No Progress" | default | hourglass |
| Execute/build failed | "Iter N: Execute Failed" / "Iter N: Build Failed" | default | warning |
| Regression reverted | "Iter N: Regression Reverted" | high | warning |
| Converged / Complete | "CONVERGED!" / "BLUEPRINT COMPLETE!" | high | tada, white_check_mark |
| Stalled (threshold) | "STALLED" / "BLUEPRINT STALLED" | high | warning |
| Max iterations | "MAX ITERATIONS" / "Blueprint Max Iterations" | high | warning |
| Supervisor active | "Supervisor Active" | low | robot_face |
| Supervisor diagnosis | "Supervisor: {root_cause}" | default | mag |
| Supervisor fix applied | "Supervisor: Fixed - {description}" | default | wrench |
| Supervisor restarting | "Supervisor: Restarting in new terminal" | default | rocket |
| Supervisor recovered | "Supervisor: RECOVERED at {health}%" | high | white_check_mark |
| Supervisor escalation | "Supervisor: NEEDS HUMAN - see escalation-report.md" | urgent | sos |
| Progress response | "[GSD-STATUS] Progress Report" | default | bar_chart |

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

The engine searches for design folders in this order:
1. Direct: {repo}\design\{type}\ (e.g., design\web\)
2. Recursive: searches up to 3 levels deep for any folder named {type} whose parent is "design"

Supported interface types: web, mcp, browser, mobile, agent

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
- gemini (optional - falls back to codex for research/spec-fix)
- dotnet (8.x)
- node, npm
- sqlcmd (optional)

Warns on untested versions but does not block execution.

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
  "phase_order": ["code-review", "create-phases", "research", "plan", "execute"]
}
```

Set ntfy_topic to "auto" for per-project auto-detection, or a specific string to use one topic for all projects.

## Token Cost Calculator

The engine includes a token cost calculator available as the `gsd-costs` command (installed globally by `install-gsd-global.ps1`). It estimates equivalent API costs for completing a project to 100%, even when using subscriptions. This enables accurate client billing and project cost forecasting.

### Dynamic Pricing

Pricing is fetched from the [LiteLLM open-source pricing database](https://github.com/BerriAI/litellm) on GitHub, a community-maintained JSON file with accurate per-token prices for all major providers. The calculator supports 6 models across 3 providers:

| Model | Input/1M | Output/1M | Used For |
|-------|----------|-----------|----------|
| Claude Sonnet 4.6 | $3.00 | $15.00 | Blueprint, verify (default) |
| Claude Opus 4.6 | $5.00 | $25.00 | Blueprint, verify (premium) |
| Claude Haiku 4.5 | $1.00 | $5.00 | Blueprint, verify (economy) |
| Codex Mini | $1.50 | $6.00 | Code generation (build/execute) |
| GPT-5.1 Codex | $1.25 | $10.00 | Code generation (alternative) |
| Gemini 2.5 Pro | $1.25 | $10.00 | Research, spec-fix |

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

### Requires Human Intervention

- Contradictory specs without -AutoResolve (e.g., "use Dapper" vs "use EF")
- Figma .fig files unreadable (export to PNG/SVG/JSON, fill figma-mapping.md)
- Auth/API key expired (re-authenticate CLI or update keys via `setup-gsd-api-keys.ps1`)
- Fundamental architecture wrong (manual correction needed)
- Code compiles but logically wrong (review storyboards + unit tests)
- Quota exhausted for more than 24 hours (wait for billing cycle)
- CLI breaking changes (update scripts)
