# GSD Engine Architecture

## Overview

The GSD Engine orchestrates three AI agents (Claude Code, Codex CLI, and Gemini CLI) through PowerShell scripts to autonomously develop, fix, and verify code against specifications. It runs unattended with comprehensive self-healing for network failures, quota limits, disk space, JSON corruption, agent boundary violations, and stalls.

The three-model strategy distributes work across independent quota pools: Claude handles reasoning (review, plan, verify), Codex handles code generation (execute), and Gemini handles research and spec-fix (saves Claude/Codex quota).

## Installed Directory Structure

After running install-gsd-all.ps1, the engine creates:

```
%USERPROFILE%\.gsd-global\
  bin\                          # CLI wrappers
    gsd-converge.cmd            # Convergence loop launcher
    gsd-remote.cmd              # Remote monitoring launcher
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
      assess.ps1                # Assessment script (gsd-assess)
  scripts\
    convergence-loop.ps1        # 5-phase convergence engine
    gsd-profile-functions.ps1   # PowerShell profile (gsd-* commands)
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
  code-review\                  # Detailed review findings
  generation-queue\
    queue-current.json          # Prioritized next batch
  agent-handoff\
    current-assignment.md       # Detailed instructions for Codex
    handoff-log.jsonl           # Execution log
  spec-conflicts\
    conflicts-to-resolve.json   # Detected spec contradictions
    resolution-summary.md       # Auto-resolution results
  logs\
    errors.jsonl                # Categorized errors (JSONL)
    iter{N}-{phase}.log         # Per-iteration agent output
  file-map.json                 # Machine-readable repo inventory
  file-map-tree.md              # Human-readable directory tree
  spec-consistency-report.md    # Spec conflict analysis
  checkpoint.json               # Crash recovery state
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
3. RESEARCH: Gemini (sandbox mode) researches patterns; falls back to Codex if unavailable
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
| Research | **Gemini** | `--sandbox` (read-only) | Saves Claude/Codex quota; falls back to Codex |
| Plan | Claude | `--allowedTools Read,Write,Bash` | Better at strategic planning |
| Execute | Codex | `--full-auto` | Faster at bulk code generation |
| Verify | Claude | `--allowedTools Read,Write,Bash` | Better at spec compliance checking |
| Spec-Fix | **Gemini** | `--approval-mode yolo` (write) | Saves Claude/Codex quota for code gen |
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

After each successful phase, state is saved to checkpoint.json. On restart, the engine resumes from the last checkpoint. Stores iteration number, phase, health score, and batch size.

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
- Gemini (research/sandbox) must NOT modify ANY files (read-only mode)
- Gemini (spec-fix) can ONLY modify docs/ and .gsd/spec-conflicts/ (never source code)
- Auto-reverts boundary violations with git checkout

### Structured Error Logging

All errors logged to .gsd/logs/errors.jsonl with categories: quota, network, disk, corrupt_json, boundary_violation, agent_crash, health_regression, spec_conflict. Each entry includes timestamp, phase, iteration, message, and resolution.

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
| Pipeline start | "GSD Converge Started" / "GSD Blueprint Started" | low | rocket |
| Iteration complete | "Iter N Complete" / "Blueprint Iter N" | default | chart_with_upwards_trend |
| Converged / Complete | "CONVERGED!" / "BLUEPRINT COMPLETE!" | high | tada, white_check_mark |
| Stalled | "STALLED" / "BLUEPRINT STALLED" | high | warning |
| Max iterations | "MAX ITERATIONS" / "Blueprint Max Iterations" | high | warning |

### Mobile Setup

1. Install the ntfy app on your phone (iOS App Store or Google Play)
2. Run any pipeline once -- the topic name prints at startup: `ntfy topic (auto): gsd-rjain-patient-portal`
3. In the ntfy app, subscribe to that topic name
4. Repeat for each project you want to monitor

Each project publishes to its own topic, so notifications are grouped by project on your phone.

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

With the -AutoResolve flag, the engine uses Gemini (`--approval-mode yolo`) to automatically resolve spec contradictions, saving Claude/Codex quota for code generation. The resolution process:

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

### Requires Human Intervention

- Contradictory specs without -AutoResolve (e.g., "use Dapper" vs "use EF")
- Figma .fig files unreadable (export to PNG/SVG/JSON, fill figma-mapping.md)
- Auth/API key expired (re-authenticate CLI)
- Fundamental architecture wrong (manual correction needed)
- Code compiles but logically wrong (review storyboards + unit tests)
- Quota exhausted for more than 24 hours (wait for billing cycle)
- CLI breaking changes (update scripts)
