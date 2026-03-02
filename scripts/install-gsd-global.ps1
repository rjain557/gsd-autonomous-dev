<#
.SYNOPSIS
    GSD Global Convergence Engine - Installer
    Installs the GSD convergence loop as a global tool for ALL projects.

.DESCRIPTION
    Installs to:
      C:\Users\rjain\.gsd-global\     - shared engine, configs, scripts
      C:\Users\rjain\.claude\          - Claude Code global commands
      C:\Users\rjain\.codex\           - Codex global instructions

    Then in any repo, just run:  gsd-converge
    Or:                          gsd-converge -DryRun
    Or from VS Code:             Ctrl+Shift+P -> "Run Task" -> "GSD: Convergence Loop"

.NOTES
    Agent Assignment Strategy (Token-Optimized):

    +---------------------+--------------+-------------------------------------+
    | GSD Phase           | Agent        | Why                                 |
    +---------------------+--------------+-------------------------------------+
    | /gsd:code-review    | CLAUDE CODE  | Short output, judgment-heavy        |
    | /gsd:create-phases  | CLAUDE CODE  | Architecture decisions, small JSON  |
    | /gsd:research       | CODEX        | Long reads, web search, many files  |
    | /gsd:plan           | CLAUDE CODE  | Prioritization, dependency graph    |
    | /gsd:execute        | CODEX        | Bulk code generation, high tokens   |
    +---------------------+--------------+-------------------------------------+

    Claude Code handles: review, create-phases, plan (3 short-output phases)
    Codex handles:       research, execute (2 long-output phases)

.USAGE
    # Install globally (one time)
    powershell -ExecutionPolicy Bypass -File install-gsd-global.ps1

    # Then in any repo:
    gsd-converge
    gsd-converge -MaxIterations 10
    gsd-converge -DryRun
#>

param(
    [string]$UserHome = $env:USERPROFILE,
    [string]$UserName = "rjain"
)

$ErrorActionPreference = "Stop"

# -- Paths --
$GsdGlobalDir = Join-Path $UserHome ".gsd-global"
$ClaudeDir    = Join-Path $UserHome ".claude"
$CodexDir     = Join-Path $UserHome ".codex"

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  GSD Global Convergence Engine - Installer" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Install locations:" -ForegroundColor Yellow
Write-Host "    Engine:      $GsdGlobalDir" -ForegroundColor White
Write-Host "    Claude Code: $ClaudeDir" -ForegroundColor White
Write-Host "    Codex:       $CodexDir" -ForegroundColor White
Write-Host ""

# ========================================================
# STEP 1: Create directory structure
# ========================================================

Write-Host "Creating global directory structure..." -ForegroundColor Yellow

$directories = @(
    $GsdGlobalDir,
    "$GsdGlobalDir\scripts",
    "$GsdGlobalDir\phases",
    "$GsdGlobalDir\prompts",
    "$GsdGlobalDir\prompts\claude",
    "$GsdGlobalDir\prompts\codex",
    "$GsdGlobalDir\config",
    "$GsdGlobalDir\templates",
    "$GsdGlobalDir\templates\project-gsd",
    $ClaudeDir,
    $CodexDir
)

foreach ($dir in $directories) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Host "   [OK] $($dir.Replace($UserHome, '~'))" -ForegroundColor DarkGreen
    } else {
        Write-Host "   [>>]  $($dir.Replace($UserHome, '~'))" -ForegroundColor DarkGray
    }
}

Write-Host ""

# ========================================================
# STEP 2: Agent Assignment Map
# ========================================================

Write-Host "Creating agent assignment configuration..." -ForegroundColor Yellow

$agentMap = @{
    version = "1.0.0"
    strategy = "token-optimized"
    description = "Claude Code for short-output thinking. Codex for long-output execution."
    phases = [ordered]@{
        "code-review" = @{
            agent = "claude-code"
            reason = "Judgment-heavy analysis. Output is a score + short findings list. Low token usage."
            estimated_output_tokens = "2000-5000"
            inputs = @("full repo scan", "requirements-matrix.json", "specs", "figma mapping")
            outputs = @("health-current.json", "requirements-matrix.json (status updates)", "drift-report.md", "review-current.md")
        }
        "create-phases" = @{
            agent = "claude-code"
            reason = "Architecture decisions. Creates phase structure and requirement decomposition. Needs high intelligence, low output volume."
            estimated_output_tokens = "3000-6000"
            inputs = @("docs\ (SDLC specs Phase A-E)", "design\figma\v## (latest)", "existing codebase structure")
            outputs = @("requirements-matrix.json (full build)", "phase dependency graph", "figma-mapping.md")
        }
        "research" = @{
            agent = "codex"
            reason = "Reads many files, searches patterns, explores codebase and docs. High input token consumption. Can run unlimited."
            estimated_output_tokens = "5000-15000"
            inputs = @("requirements-matrix.json", "specs", "figma designs", "existing code", "external references")
            outputs = @("research-findings.md", "pattern-analysis.md", "dependency-map.json", "tech-decisions.md")
        }
        "plan" = @{
            agent = "claude-code"
            reason = "Prioritization and dependency ordering. Short output: a ranked queue of what to build next. High judgment, low tokens."
            estimated_output_tokens = "1500-4000"
            inputs = @("requirements-matrix.json", "research findings", "drift-report.md")
            outputs = @("queue-current.json", "current-assignment.md")
        }
        "execute" = @{
            agent = "codex"
            reason = "BULK CODE GENERATION. This is where 80% of tokens go. Creates/modifies many files. Codex has no token cap - let it run."
            estimated_output_tokens = "15000-100000+"
            inputs = @("current-assignment.md", "queue-current.json", "specs", "figma mapping", "phase standards")
            outputs = @("source code files (created/modified)", "handoff-log.jsonl entry")
        }
    }
    token_budget_summary = @{
        claude_code_per_iteration = "6500-15000 tokens (review + create-phases + plan)"
        codex_per_iteration = "20000-115000+ tokens (research + execute)"
        claude_code_monthly_estimate = "~150K-300K tokens for 20 iterations"
        codex_monthly_estimate = "unlimited (full-auto mode)"
        optimization = "Claude Code stays well under $200/mo cap. Codex does the heavy lifting."
    }
} | ConvertTo-Json -Depth 5

Set-Content -Path "$GsdGlobalDir\config\agent-map.json" -Value $agentMap -Encoding UTF8
Write-Host "   [OK] config\agent-map.json" -ForegroundColor DarkGreen

# -- Global loop config --
$globalConfig = @{
    version = "1.0.0"
    target_health = 100
    max_iterations = 20
    stall_threshold = 3
    batch_size_min = 3
    batch_size_max = 8
    figma = @{
        base_path = "design\figma"
        version_pattern = "^v(\d+)$"
        auto_detect_latest = $true
    }
    sdlc_docs = @{
        path = "docs"
        phases = @("Phase-A", "Phase-B", "Phase-C", "Phase-D", "Phase-E")
    }
    patterns = @{
        backend = ".NET 8 with Dapper"
        database = "SQL Server stored procedures only"
        frontend = "React 18"
        api = "Contract-first, API-first"
        compliance = @("HIPAA", "SOC 2", "PCI", "GDPR")
    }
    project_gsd_dir = ".gsd"
    phase_order = @("code-review", "create-phases", "research", "plan", "execute")
} | ConvertTo-Json -Depth 4

Set-Content -Path "$GsdGlobalDir\config\global-config.json" -Value $globalConfig -Encoding UTF8
Write-Host "   [OK] config\global-config.json" -ForegroundColor DarkGreen

Write-Host ""

# ========================================================
# STEP 3: Claude Code global prompts (SHORT, FOCUSED)
# ========================================================

Write-Host "[SEARCH] Creating Claude Code prompts (review, create-phases, plan)..." -ForegroundColor Yellow

# -- Claude: Code Review --
$claudeReview = @'
# GSD Code Review - Claude Code Phase

You are the REVIEWER in a convergence loop. Your output must be CONCISE to conserve tokens.

## Context
- Iteration: {{ITERATION}}
- Current health: {{HEALTH}}%
- Target: 100%
- Project .gsd dir: {{GSD_DIR}}

## Read
1. {{GSD_DIR}}\health\requirements-matrix.json
2. {{GSD_DIR}}\specs\figma-mapping.md
3. {{GSD_DIR}}\specs\sdlc-reference.md
4. Source code (focus on files changed since last iteration if iteration > 1)

## Do
1. SCAN each requirement against the codebase
2. UPDATE status in requirements-matrix.json: satisfied | partial | not_started
3. CALCULATE health_score = (satisfied / total) * 100
4. WRITE health-current.json, append to health-history.jsonl
5. WRITE drift-report.md (keep SHORT - bullet points only, max 50 lines)
6. WRITE review-current.md (findings with file:line refs, max 100 lines)

## Token Budget
You have ~3000 output tokens for this phase. Be surgical. No prose. Tables and bullets only.
If health >= 100, set status "passed" and stop.
'@

Set-Content -Path "$GsdGlobalDir\prompts\claude\code-review.md" -Value $claudeReview -Encoding UTF8
Write-Host "   [OK] prompts\claude\code-review.md" -ForegroundColor DarkGreen

# -- Claude: Create Phases --
$claudeCreatePhases = @'
# GSD Create Phases - Claude Code Phase

You are the ARCHITECT. Build the requirements matrix from spec docs and Figma designs.
This runs ONCE at the start (Phase 0), or when specs/Figma change significantly.

## Context
- Project: {{REPO_ROOT}}
- Figma: {{FIGMA_PATH}} (version {{FIGMA_VERSION}})
- SDLC docs: docs\ (Phase A through Phase E)
- Project .gsd dir: {{GSD_DIR}}

## Read
1. Every file in docs\ (SDLC specification documents)
2. {{GSD_DIR}}\specs\figma-mapping.md
3. Design files in {{FIGMA_PATH}}
4. Existing codebase structure (scan src\ or equivalent)

## Do
1. EXTRACT every discrete requirement into requirements-matrix.json:
   - id, source (spec|figma|compliance), sdlc_phase, description
   - figma_frame (if UI), spec_doc (which doc defines it)
   - status (scan code: satisfied|partial|not_started)
   - depends_on, pattern, priority
2. UPDATE figma-mapping.md with component-to-file mappings
3. WRITE initial health-current.json
4. WRITE drift-report.md

## Token Budget
~5000 output tokens. The matrix JSON will be the bulk. Keep descriptions to one sentence each.
Focus on COMPLETENESS - every missed requirement is a gap that won't get built.
'@

Set-Content -Path "$GsdGlobalDir\prompts\claude\create-phases.md" -Value $claudeCreatePhases -Encoding UTF8
Write-Host "   [OK] prompts\claude\create-phases.md" -ForegroundColor DarkGreen

# -- Claude: Plan --
$claudePlan = @'
# GSD Plan - Claude Code Phase

You are the PLANNER. Select and prioritize the next batch of work.

## Context
- Iteration: {{ITERATION}}
- Health: {{HEALTH}}%
- Project .gsd dir: {{GSD_DIR}}

## Read
1. {{GSD_DIR}}\health\requirements-matrix.json (focus on not_started and partial)
2. {{GSD_DIR}}\health\drift-report.md
3. {{GSD_DIR}}\research\research-findings.md (if exists, from Codex research phase)
4. {{GSD_DIR}}\research\dependency-map.json (if exists)

## Do
1. SELECT 3-8 requirements for the next execution batch
   Priority order:
   a. Dependencies first (foundations before features)
   b. SDLC phase order (A -> B -> C -> D -> E)
   c. Backend before frontend (APIs before UI)
   d. Group related requirements (all endpoints for one entity)
2. WRITE queue-current.json:
   { "iteration": N, "batch": [ { "req_id", "description", "generation_instructions", "target_files", "pattern" } ] }
3. WRITE current-assignment.md for Codex:
   - Exact file paths to create/modify
   - Patterns to follow
   - Figma refs for UI components
   - Acceptance criteria per requirement

## Token Budget
~3000 output tokens. The queue JSON + assignment doc. Be specific in instructions - 
Codex needs exact file paths and clear acceptance criteria to execute well.
'@

Set-Content -Path "$GsdGlobalDir\prompts\claude\plan.md" -Value $claudePlan -Encoding UTF8
Write-Host "   [OK] prompts\claude\plan.md" -ForegroundColor DarkGreen

Write-Host ""

# ========================================================
# STEP 4: Codex global prompts (LONG, DETAILED)
# ========================================================

Write-Host "[WRENCH] Creating Codex prompts (research, execute)..." -ForegroundColor Yellow

# -- Codex: Research --
$codexResearch = @'
# GSD Research - Codex Phase

You are the RESEARCHER. Deeply analyze the codebase, specs, and Figma to prepare
for code generation. You have UNLIMITED tokens - be thorough.

## Context
- Iteration: {{ITERATION}}
- Health: {{HEALTH}}%
- Project .gsd dir: {{GSD_DIR}}

## Read (read ALL of these thoroughly)
1. {{GSD_DIR}}\health\requirements-matrix.json - every requirement
2. docs\ - ALL SDLC specification documents (Phase A through E), read every file completely
3. {{FIGMA_PATH}} - ALL Figma design deliverables
4. {{GSD_DIR}}\specs\figma-mapping.md - current component mappings
5. {{GSD_DIR}}\specs\sdlc-reference.md - doc index
6. Existing source code - scan the full codebase structure and key files

## Do
1. ANALYZE the current codebase:
   - What patterns are in use?
   - What frameworks, libraries, dependencies exist?
   - What's the folder structure?
   - What's already implemented vs gaps?

2. ANALYZE specs vs reality:
   - For each not_started requirement, what exactly needs to be built?
   - What are the data models needed?
   - What API contracts are specified?
   - What stored procedures need to exist?

3. ANALYZE Figma designs:
   - What React components are needed?
   - What design tokens (colors, fonts, spacing) are used?
   - What interactions/states are defined?
   - Map each Figma frame to a concrete component path

4. BUILD dependency map:
   - Which requirements depend on which?
   - What order should things be built?
   - What shared utilities/types are needed first?

5. IDENTIFY patterns and decisions:
   - Authentication approach
   - State management
   - Routing structure
   - Error handling patterns
   - Compliance implementation specifics

## Write
1. {{GSD_DIR}}\research\research-findings.md - comprehensive analysis
2. {{GSD_DIR}}\research\dependency-map.json - requirement dependency graph
3. {{GSD_DIR}}\research\pattern-analysis.md - detected and recommended patterns
4. {{GSD_DIR}}\research\tech-decisions.md - technical decisions and rationale
5. {{GSD_DIR}}\research\figma-analysis.md - detailed Figma-to-code mapping
6. UPDATE {{GSD_DIR}}\specs\figma-mapping.md with any new component mappings found

## Boundaries
- DO NOT modify source code in this phase
- DO NOT modify health/ or code-review/ files
- ONLY write to {{GSD_DIR}}\research\ and update specs\figma-mapping.md
'@

Set-Content -Path "$GsdGlobalDir\prompts\codex\research.md" -Value $codexResearch -Encoding UTF8
Write-Host "   [OK] prompts\codex\research.md" -ForegroundColor DarkGreen

# -- Codex: Execute --
$codexExecute = @'
# GSD Execute - Codex Phase

You are the DEVELOPER. Generate ALL code needed to satisfy the current batch.
You have UNLIMITED tokens - generate complete, production-ready files.

## Context
- Iteration: {{ITERATION}}
- Health: {{HEALTH}}%
- Project .gsd dir: {{GSD_DIR}}

## Read
1. {{GSD_DIR}}\agent-handoff\current-assignment.md - YOUR SPECIFIC INSTRUCTIONS
2. {{GSD_DIR}}\generation-queue\queue-current.json - the prioritized batch
3. {{GSD_DIR}}\health\requirements-matrix.json - full requirements context
4. {{GSD_DIR}}\research\ - all research findings (patterns, dependencies, tech decisions)
5. {{GSD_DIR}}\specs\ - SDLC reference + Figma mapping
6. docs\ - specification documents (Phase A-E)
7. {{FIGMA_PATH}} - Figma design deliverables

## Project Patterns (STRICT - follow exactly)

### Backend (.NET 8)
- Dapper for ALL data access (never Entity Framework)
- SQL Server stored procedures ONLY (never inline SQL)
- API-first, contract-first (implement against defined contracts)
- RESTful endpoints with proper HTTP status codes
- Input validation with FluentValidation or DataAnnotations
- Structured logging (Serilog pattern)
- Dependency injection for all services
- Repository pattern wrapping Dapper calls to stored procedures

### Frontend (React 18)
- Functional components with hooks ONLY (no class components)
- Match Figma designs EXACTLY: spacing, colors, typography, states
- Responsive breakpoints as defined in Figma
- Accessibility: ARIA labels, keyboard navigation, focus management
- Error boundaries on route-level components
- Loading states and skeleton screens

### Database (SQL Server)
- ALL data access through stored procedures
- Parameterized queries (never string concatenation)
- Proper indexing for query patterns defined in specs
- Migration scripts in order (V001__description.sql pattern)
- Audit columns: CreatedAt, CreatedBy, ModifiedAt, ModifiedBy

### Compliance
- HIPAA: Encrypt PHI at rest (TDE) and in transit (TLS), audit log all PHI access
- SOC 2: Role-based access control, change management trails
- PCI: Tokenize card data, never store raw card numbers
- GDPR: Consent tracking, data export/deletion endpoints

## Execute
For each requirement in the batch:
1. Create/modify files as specified in current-assignment.md
2. Write COMPLETE files (not snippets - full production-ready code)
3. Include error handling, logging, input validation
4. Add JSDoc/XML doc comments
5. Create corresponding stored procedures for any new data access
6. Create corresponding React components for any new UI

## After Generating
- Verify files have no syntax errors (run quick checks if possible)
- Append completion summary to {{GSD_DIR}}\agent-handoff\handoff-log.jsonl:
  {"agent":"codex","action":"execute-complete","iteration":N,"files_created":[...],"files_modified":[...],"requirements_addressed":[...],"timestamp":"..."}

## Boundaries
- DO NOT modify anything in {{GSD_DIR}}\code-review\
- DO NOT modify anything in {{GSD_DIR}}\health\
- DO NOT modify anything in {{GSD_DIR}}\generation-queue\
- WRITE source code + handoff log entries ONLY
'@

Set-Content -Path "$GsdGlobalDir\prompts\codex\execute.md" -Value $codexExecute -Encoding UTF8
Write-Host "   [OK] prompts\codex\execute.md" -ForegroundColor DarkGreen

Write-Host ""

# ========================================================
# STEP 5: GSD phase definitions (shared by both agents)
# ========================================================

Write-Host "[BOOK] Creating shared GSD phase definitions..." -ForegroundColor Yellow

$phasesReadme = @"
# GSD Convergence Engine - Phase Definitions

## Phase Flow Per Iteration

``````
+-------------------------------------------------------------+
|                    GSD CONVERGENCE LOOP                      |
|                                                             |
|  +--------------+    CLAUDE CODE (token-conserving)         |
|  | 1. CODE      |    Scan repo vs matrix. Score health.     |
|  |    REVIEW    |    Update requirement statuses.            |
|  |              |    Output: ~3K tokens                      |
|  +------+-------+                                           |
|         | health < 100%                                     |
|         ?                                                   |
|  +--------------+    CLAUDE CODE (one-time or on spec       |
|  | 2. CREATE    |    change). Extract all requirements      |
|  |    PHASES    |    from docs + Figma into matrix.          |
|  |              |    Output: ~5K tokens                      |
|  +------+-------+                                           |
|         ?                                                   |
|  +--------------+    CODEX (unlimited tokens)               |
|  | 3. RESEARCH  |    Deep-read specs, Figma, codebase.      |
|  |              |    Build dependency maps, pattern guides.  |
|  |              |    Output: ~10K+ tokens                    |
|  +------+-------+                                           |
|         ?                                                   |
|  +--------------+    CLAUDE CODE (token-conserving)         |
|  | 4. PLAN      |    Prioritize next 3-8 requirements.      |
|  |              |    Write specific generation instructions. |
|  |              |    Output: ~3K tokens                      |
|  +------+-------+                                           |
|         ?                                                   |
|  +--------------+    CODEX (unlimited tokens)               |
|  | 5. EXECUTE   |    Generate ALL code for the batch.       |
|  |              |    Full files, stored procs, components.   |
|  |              |    Output: ~50K+ tokens                    |
|  +------+-------+                                           |
|         |                                                   |
|         ? git commit                                        |
|     LOOP BACK TO 1                                          |
+-------------------------------------------------------------+
``````

## Token Budget Per Iteration

| Phase         | Agent       | Est. Output Tokens | Monthly @ 20 iters |
|---------------|-------------|-------------------:|-------------------:|
| code-review   | Claude Code |       2,000-5,000  |     40K-100K       |
| create-phases | Claude Code |       3,000-6,000  |     one-time ~5K   |
| research      | Codex       |      5,000-15,000  |     unlimited      |
| plan          | Claude Code |       1,500-4,000  |     30K-80K        |
| execute       | Codex       |    15,000-100,000+ |     unlimited      |
|               |             |                    |                    |
| **Claude Code total** |     |   **~11K/iter**    |   **~220K/mo**     |
| **Codex total**       |     |   **~65K+/iter**   |   **unlimited**    |

Claude Code stays well under the `$`200/mo cap. Codex does the heavy lifting.

## Agent Boundaries

| Domain                   | Claude Code (Reviewer/Architect/Planner) | Codex (Researcher/Developer) |
|--------------------------|------------------------------------------|------------------------------|
| Source code              | READ only                                | READ + WRITE                 |
| .gsd\health\             | READ + WRITE                             | READ only                    |
| .gsd\code-review\        | READ + WRITE                             | READ only                    |
| .gsd\generation-queue\   | READ + WRITE                             | READ only                    |
| .gsd\research\           | READ only                                | READ + WRITE                 |
| .gsd\agent-handoff\      | WRITE current-assignment.md              | APPEND handoff-log.jsonl     |
| docs\                    | READ only                                | READ only                    |
| design\figma\            | READ only                                | READ only                    |
"@

Set-Content -Path "$GsdGlobalDir\phases\README.md" -Value $phasesReadme -Encoding UTF8
Write-Host "   [OK] phases\README.md" -ForegroundColor DarkGreen

Write-Host ""

# ========================================================
# STEP 6: Per-project init template
# ========================================================

Write-Host "[CLIP] Creating per-project init template..." -ForegroundColor Yellow

$projectInitTemplate = @'
# Per-project .gsd directory structure
# Created by: gsd-init (from global engine)
#
# This gets created in each repo when you first run gsd-converge

.gsd\
+-- health\
|   +-- health-current.json
|   +-- health-history.jsonl
|   +-- requirements-matrix.json
|   +-- drift-report.md
+-- code-review\
|   +-- review-current.md
|   +-- review-history\
+-- research\
|   +-- research-findings.md
|   +-- dependency-map.json
|   +-- pattern-analysis.md
|   +-- tech-decisions.md
|   +-- figma-analysis.md
+-- generation-queue\
|   +-- queue-current.json
|   +-- completed\
+-- agent-handoff\
|   +-- current-assignment.md
|   +-- handoff-log.jsonl
+-- specs\
|   +-- figma-mapping.md      (auto-populated from design\figma\v##)
|   +-- sdlc-reference.md     (auto-populated from docs\)
+-- logs\
'@

Set-Content -Path "$GsdGlobalDir\templates\project-gsd\STRUCTURE.md" -Value $projectInitTemplate -Encoding UTF8
Write-Host "   [OK] templates\project-gsd\STRUCTURE.md" -ForegroundColor DarkGreen

Write-Host ""

# ========================================================
# STEP 7: Main convergence script (GLOBAL)
# ========================================================

Write-Host "[SYNC] Creating global convergence-loop.ps1..." -ForegroundColor Yellow

$mainScript = @'
<#
.SYNOPSIS
    GSD Convergence Loop - runs from any project repo.
    Reads global config from ~\.gsd-global\, creates per-project .gsd\ state.

.USAGE
    cd C:\path\to\any\repo
    gsd-converge
    gsd-converge -MaxIterations 10
    gsd-converge -DryRun
    gsd-converge -SkipInit
    gsd-converge -SkipResearch    # skip codex research phase to save time
#>

param(
    [int]$MaxIterations = 20,
    [int]$StallThreshold = 3,
    [switch]$SkipInit,
    [switch]$SkipResearch,
    [switch]$DryRun
)

$ErrorActionPreference = "Continue"
$RepoRoot = (Get-Location).Path
$UserHome = $env:USERPROFILE
$GlobalDir = Join-Path $UserHome ".gsd-global"
$GsdDir = Join-Path $RepoRoot ".gsd"

# -- Validate global install --
if (-not (Test-Path $GlobalDir)) {
    Write-Host "[XX] GSD Global Engine not installed. Run install-gsd-global.ps1 first." -ForegroundColor Red
    exit 1
}

# -- Detect latest Figma version --
$figmaBase = Join-Path $RepoRoot "design\figma"
$FigmaVersion = "none"
$FigmaPath = "none"

if (Test-Path $figmaBase) {
    $latest = Get-ChildItem -Path $figmaBase -Directory |
        Where-Object { $_.Name -match '^v(\d+)$' } |
        Sort-Object { [int]($_.Name -replace '^v', '') } -Descending |
        Select-Object -First 1

    if ($latest) {
        $FigmaVersion = $latest.Name
        $FigmaPath = "design\figma\$FigmaVersion"
    }
}

# -- Validate repo structure --
$docsPath = Join-Path $RepoRoot "docs"
$hasDocs = Test-Path $docsPath
$hasFigma = $FigmaVersion -ne "none"

if (-not $hasDocs) {
    Write-Host "[!!]  No docs\ directory found. SDLC spec-based requirements will be limited." -ForegroundColor Yellow
}
if (-not $hasFigma) {
    Write-Host "[!!]  No design\figma\v## found. Figma-based requirements will be limited." -ForegroundColor Yellow
}

# -- Initialize per-project .gsd if needed --
$projectDirs = @(
    "$GsdDir\health", "$GsdDir\health\history",
    "$GsdDir\code-review", "$GsdDir\code-review\review-history",
    "$GsdDir\research",
    "$GsdDir\generation-queue", "$GsdDir\generation-queue\completed",
    "$GsdDir\agent-handoff",
    "$GsdDir\specs",
    "$GsdDir\logs"
)

foreach ($dir in $projectDirs) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

# -- Init project health if missing --
$HealthFile = Join-Path $GsdDir "health\health-current.json"
$MatrixFile = Join-Path $GsdDir "health\requirements-matrix.json"
$HealthLog = Join-Path $GsdDir "health\health-history.jsonl"
$HandoffLog = Join-Path $GsdDir "agent-handoff\handoff-log.jsonl"

if (-not (Test-Path $HealthFile)) {
    @{ health_score=0; total_requirements=0; satisfied=0; partial=0; not_started=0; iteration=0; last_agent="none"; figma_version=$FigmaVersion; last_updated=(Get-Date -Format "o") } |
        ConvertTo-Json -Depth 3 | Set-Content $HealthFile -Encoding UTF8
}
if (-not (Test-Path $MatrixFile)) {
    @{ meta=@{ total_requirements=0; satisfied=0; partial=0; not_started=0; health_score=0; figma_version=$FigmaVersion; last_updated=(Get-Date -Format "o"); iteration=0 }; requirements=@() } |
        ConvertTo-Json -Depth 4 | Set-Content $MatrixFile -Encoding UTF8
}

# -- Auto-generate specs references if missing --
$figmaMappingFile = Join-Path $GsdDir "specs\figma-mapping.md"
if (-not (Test-Path $figmaMappingFile) -and $hasFigma) {
    $figmaFiles = Get-ChildItem -Path (Join-Path $RepoRoot $FigmaPath) -Recurse -File
    $lines = $figmaFiles | ForEach-Object {
        $rel = $_.FullName.Replace((Join-Path $RepoRoot $FigmaPath), "").TrimStart("\")
        "| $rel | | | not_started |"
    }
    $content = "# Figma Mapping - $FigmaVersion`n`n| Figma File | Component Path | Description | Status |`n|---|---|---|---|`n$($lines -join "`n")"
    Set-Content -Path $figmaMappingFile -Value $content -Encoding UTF8
}

$sdlcRefFile = Join-Path $GsdDir "specs\sdlc-reference.md"
if (-not (Test-Path $sdlcRefFile) -and $hasDocs) {
    $docFiles = Get-ChildItem -Path $docsPath -File -Recurse
    $lines = $docFiles | ForEach-Object {
        $rel = $_.FullName.Replace($RepoRoot, "").TrimStart("\")
        "- [$($_.Name)]($rel)"
    }
    $content = "# SDLC Specification Documents`n`nSource: docs\`n`n$($lines -join "`n")"
    Set-Content -Path $sdlcRefFile -Value $content -Encoding UTF8
}

# -- Helper functions --
function Get-Health {
    try {
        $json = Get-Content $HealthFile -Raw | ConvertFrom-Json
        return [double]$json.health_score
    } catch { return 0 }
}

function Log-Handoff($agent, $action, $iter, $health) {
    $entry = @{ agent=$agent; action=$action; iteration=$iter; health=$health; figma_version=$FigmaVersion; timestamp=(Get-Date -Format "o") } |
        ConvertTo-Json -Compress
    Add-Content -Path $HandoffLog -Value $entry -Encoding UTF8
}

function Resolve-Prompt($templatePath, $iter, $health) {
    $text = Get-Content $templatePath -Raw
    return $text.Replace("{{ITERATION}}", "$iter").Replace("{{HEALTH}}", "$health").Replace("{{GSD_DIR}}", $GsdDir).Replace("{{REPO_ROOT}}", $RepoRoot).Replace("{{FIGMA_PATH}}", $FigmaPath).Replace("{{FIGMA_VERSION}}", $FigmaVersion)
}

# -- Start --
$Iteration = 0
$Health = Get-Health
$StallCount = 0
$TargetHealth = 100

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  GSD Convergence Loop" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  Repo:        $RepoRoot" -ForegroundColor White
Write-Host "  Figma:       $FigmaVersion ($FigmaPath)" -ForegroundColor White
Write-Host "  Docs:        $(if ($hasDocs) { 'docs\' } else { 'none' })" -ForegroundColor White
Write-Host "  Health:      ${Health}% -> target ${TargetHealth}%" -ForegroundColor White
Write-Host "  Iterations:  max $MaxIterations, stall after $StallThreshold" -ForegroundColor White
Write-Host "  Global:      $GlobalDir" -ForegroundColor DarkGray
if ($DryRun) { Write-Host "  MODE:        DRY RUN" -ForegroundColor Yellow }
if ($SkipResearch) { Write-Host "  SKIP:        Research phase" -ForegroundColor Yellow }
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

# ========================================================
# PHASE 0: Create Phases (Claude Code - one time)
# ========================================================
$matrixContent = Get-Content $MatrixFile -Raw | ConvertFrom-Json
$hasRequirements = $matrixContent.requirements.Count -gt 0

if (-not $hasRequirements -and -not $SkipInit) {
    Write-Host "[CLIP] Phase 0: CREATE PHASES (Claude Code - one time)" -ForegroundColor Magenta
    Log-Handoff "claude-code" "create-phases" 0 0

    $prompt = Resolve-Prompt "$GlobalDir\prompts\claude\create-phases.md" 0 0

    if (-not $DryRun) {
        claude -p $prompt --allowedTools "Read,Write,Edit,Bash,mcp__*" 2>&1 |
            Tee-Object "$GsdDir\logs\phase0-create-phases.log"
    } else {
        Write-Host "   [DRY RUN] claude -p <create-phases prompt>" -ForegroundColor DarkYellow
    }

    $Health = Get-Health
    Write-Host "[OK] Matrix built. Health: ${Health}%" -ForegroundColor Green
    Write-Host ""
}

# ========================================================
# MAIN LOOP
# ========================================================
while ($Health -lt $TargetHealth -and $Iteration -lt $MaxIterations -and $StallCount -lt $StallThreshold) {
    $Iteration++
    $PrevHealth = $Health

    Write-Host "=== Iteration $Iteration / $MaxIterations | Health: ${Health}% ===" -ForegroundColor White

    # == 1. CODE REVIEW (Claude Code) ==
    Write-Host "[SEARCH] [$Iteration] CLAUDE CODE -> code-review" -ForegroundColor Cyan
    Log-Handoff "claude-code" "code-review" $Iteration $Health

    $prompt = Resolve-Prompt "$GlobalDir\prompts\claude\code-review.md" $Iteration $Health

    if (-not $DryRun) {
        claude -p $prompt --allowedTools "Read,Write,Edit,Bash,mcp__*" 2>&1 |
            Tee-Object "$GsdDir\logs\iter${Iteration}-1-code-review.log"
    } else {
        Write-Host "   [DRY RUN] claude -> code-review" -ForegroundColor DarkYellow
    }

    $Health = Get-Health
    Write-Host "   [CHART] Health: ${Health}%" -ForegroundColor Yellow

    if ($Health -ge $TargetHealth) {
        Write-Host "[OK] CONVERGED at code-review!" -ForegroundColor Green
        break
    }

    # == 2. RESEARCH (Codex) - optional ==
    if (-not $SkipResearch) {
        Write-Host "[$Iteration] CODEX -> research" -ForegroundColor Magenta
        Log-Handoff "codex" "research" $Iteration $Health

        # Ensure research dir exists
        $researchDir = Join-Path $GsdDir "research"
        if (-not (Test-Path $researchDir)) { New-Item -ItemType Directory -Path $researchDir -Force | Out-Null }

        $prompt = Resolve-Prompt "$GlobalDir\prompts\codex\research.md" $Iteration $Health

        if (-not $DryRun) {
            codex exec --full-auto $prompt 2>&1 |
                Tee-Object "$GsdDir\logs\iter${Iteration}-2-research.log"
        } else {
            Write-Host "   [DRY RUN] codex -> research" -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "[>>]  [$Iteration] Skipping research phase" -ForegroundColor DarkGray
    }

    # == 3. PLAN (Claude Code) ==
    Write-Host "[$Iteration] CLAUDE CODE -> plan" -ForegroundColor Cyan
    Log-Handoff "claude-code" "plan" $Iteration $Health

    $prompt = Resolve-Prompt "$GlobalDir\prompts\claude\plan.md" $Iteration $Health

    if (-not $DryRun) {
        claude -p $prompt --allowedTools "Read,Write,Edit,Bash,mcp__*" 2>&1 |
            Tee-Object "$GsdDir\logs\iter${Iteration}-3-plan.log"
    } else {
        Write-Host "   [DRY RUN] claude -> plan" -ForegroundColor DarkYellow
    }

    # == 4. EXECUTE (Codex) ==
    Write-Host "[WRENCH] [$Iteration] CODEX -> execute" -ForegroundColor Magenta
    Log-Handoff "codex" "execute" $Iteration $Health

    $prompt = Resolve-Prompt "$GlobalDir\prompts\codex\execute.md" $Iteration $Health

    if (-not $DryRun) {
        codex exec --full-auto $prompt 2>&1 |
            Tee-Object "$GsdDir\logs\iter${Iteration}-4-execute.log"

        # Git commit
        git add -A
        git commit -m "gsd: iter $Iteration execute (health: ${Health}%)" --no-verify 2>$null
    } else {
        Write-Host "   [DRY RUN] codex -> execute" -ForegroundColor DarkYellow
    }

    # -- Stall detection --
    $NewHealth = Get-Health
    if ($NewHealth -le $PrevHealth) {
        $StallCount++
        Write-Host "[!!]  No progress: ${PrevHealth}% -> ${NewHealth}% | Stall $StallCount/$StallThreshold" -ForegroundColor DarkYellow

        if ($StallCount -ge $StallThreshold) {
            Write-Host "[STOP] Stalled. Running Claude Code diagnosis..." -ForegroundColor Red
            if (-not $DryRun) {
                claude -p "The convergence loop stalled for $StallCount iterations at ${NewHealth}%. Read .gsd\health\health-history.jsonl, drift-report.md, and requirements-matrix.json. Diagnose why. Write to .gsd\health\stall-diagnosis.md." `
                    --allowedTools "Read,Write,Bash" 2>&1 |
                    Tee-Object "$GsdDir\logs\stall-diagnosis-$Iteration.log"
            }
            break
        }
    } else {
        $StallCount = 0
    }

    $Health = $NewHealth
    Write-Host "[SYNC] [$Iteration] Done. Health: ${Health}%`n" -ForegroundColor Cyan
    Start-Sleep -Seconds 2
}

# ========================================================
# FINAL
# ========================================================
Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
$FinalHealth = Get-Health

if ($FinalHealth -ge $TargetHealth) {
    Write-Host "[PARTY] CONVERGENCE ACHIEVED - ${FinalHealth}% in $Iteration iterations" -ForegroundColor Green
    if (-not $DryRun) {
        git add -A; git commit -m "gsd: CONVERGED - 100% health in $Iteration iterations" --no-verify 2>$null
        git tag "gsd-converged-$(Get-Date -Format 'yyyyMMdd-HHmmss')" 2>$null
    }
} elseif ($StallCount -ge $StallThreshold) {
    Write-Host "[STOP] STALLED at ${FinalHealth}% - see .gsd\health\stall-diagnosis.md" -ForegroundColor Red
} else {
    Write-Host "[!!]  MAX ITERATIONS at ${FinalHealth}% - see .gsd\health\drift-report.md" -ForegroundColor Yellow
}

Write-Host "  Logs: .gsd\logs\" -ForegroundColor DarkGray
Write-Host "=========================================================" -ForegroundColor Cyan
'@

Set-Content -Path "$GsdGlobalDir\scripts\convergence-loop.ps1" -Value $mainScript -Encoding UTF8
Write-Host "   [OK] scripts\convergence-loop.ps1" -ForegroundColor DarkGreen

Write-Host ""

# ========================================================
# STEP 8: Create global alias / command
# ========================================================

Write-Host "Setting up global 'gsd-converge' command..." -ForegroundColor Yellow

# Create a wrapper script in a PATH-accessible location
$scriptsOnPath = Join-Path $UserHome ".gsd-global\bin"
if (-not (Test-Path $scriptsOnPath)) {
    New-Item -ItemType Directory -Path $scriptsOnPath -Force | Out-Null
}

$wrapperCmd = @"
@echo off
powershell -ExecutionPolicy Bypass -File "%USERPROFILE%\.gsd-global\scripts\convergence-loop.ps1" %*
"@

Set-Content -Path "$scriptsOnPath\gsd-converge.cmd" -Value $wrapperCmd -Encoding ASCII
Write-Host "   [OK] bin\gsd-converge.cmd" -ForegroundColor DarkGreen

# Create PowerShell function in profile
$wrapperPs1 = @"
function gsd-converge {
    param([switch]`$DryRun, [switch]`$SkipInit, [switch]`$SkipResearch, [int]`$MaxIterations = 20, [int]`$StallThreshold = 3)
    `$params = @{ MaxIterations = `$MaxIterations; StallThreshold = `$StallThreshold }
    if (`$DryRun) { `$params.DryRun = `$true }
    if (`$SkipInit) { `$params.SkipInit = `$true }
    if (`$SkipResearch) { `$params.SkipResearch = `$true }
    & "`$env:USERPROFILE\.gsd-global\scripts\convergence-loop.ps1" @params
}

function gsd-init {
    Write-Host "Initializing .gsd\ for current project..." -ForegroundColor Yellow
    & "`$env:USERPROFILE\.gsd-global\scripts\convergence-loop.ps1" -MaxIterations 0
}
"@

Set-Content -Path "$GsdGlobalDir\scripts\gsd-profile-functions.ps1" -Value $wrapperPs1 -Encoding UTF8
Write-Host "   [OK] scripts\gsd-profile-functions.ps1" -ForegroundColor DarkGreen

# Add to ALL PowerShell profile paths (AllHosts + CurrentHost for console and VS Code)
$gsdSourceBlock = @"
`$gsdFunctions = Join-Path `$env:USERPROFILE '.gsd-global\scripts\gsd-profile-functions.ps1'
if (Test-Path `$gsdFunctions) { . `$gsdFunctions }
"@

$profileDirs = @(
    (Join-Path $env:USERPROFILE "Documents\PowerShell"),
    (Join-Path $env:USERPROFILE "Documents\WindowsPowerShell")
)
$profileNames = @("profile.ps1", "Microsoft.PowerShell_profile.ps1", "Microsoft.VSCode_profile.ps1")

foreach ($dir in $profileDirs) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    foreach ($name in $profileNames) {
        $p = Join-Path $dir $name
        if (Test-Path $p) {
            $content = Get-Content $p -Raw -ErrorAction SilentlyContinue
            if ($content -notmatch "gsd-profile-functions") {
                Add-Content -Path $p -Value "`n$gsdSourceBlock" -Encoding UTF8
                Write-Host "   [OK] Updated $name in $dir" -ForegroundColor DarkGreen
            }
        } else {
            Set-Content -Path $p -Value $gsdSourceBlock -Encoding UTF8
            Write-Host "   [OK] Created $name in $dir" -ForegroundColor DarkGreen
        }
    }
}
Write-Host "   [>>]  GSD functions registered in all PowerShell profiles" -ForegroundColor DarkGray

# Add bin to PATH if not already
$currentPath = [Environment]::GetEnvironmentVariable("PATH", "User")
if ($currentPath -notlike "*$scriptsOnPath*") {
    [Environment]::SetEnvironmentVariable("PATH", "$currentPath;$scriptsOnPath", "User")
    Write-Host "   [OK] Added $scriptsOnPath to user PATH" -ForegroundColor DarkGreen
    Write-Host "   [!!]  Restart your terminal for PATH change to take effect" -ForegroundColor Yellow
} else {
    Write-Host "   [>>]  bin\ already in PATH" -ForegroundColor DarkGray
}

Write-Host ""

# ========================================================
# STEP 9: Claude Code global config (.claude)
# ========================================================

Write-Host "[SEARCH] Configuring Claude Code global settings..." -ForegroundColor Yellow

$claudeSettings = @"
# Claude Code - GSD Global Configuration
# Location: $ClaudeDir\CLAUDE.md
# This file is read by Claude Code for global context.

## GSD Convergence Engine

When you see references to GSD phases, convergence loops, or health scores,
the global engine is at: $GsdGlobalDir

### Your Role in the Loop
You handle 3 phases (token-efficient, judgment-heavy):
1. **code-review**: Score repo health, update requirement statuses
2. **create-phases**: Extract requirements from specs + Figma (one-time)
3. **plan**: Prioritize next batch, write generation instructions

### Token Discipline
- Keep ALL outputs under 5000 tokens per phase
- Use tables and bullets, never prose paragraphs
- Drift reports: max 50 lines
- Review findings: max 100 lines
- Plan output: queue JSON + assignment doc only

### Agent Boundaries
- You READ source code but NEVER modify it
- You WRITE to: .gsd\health\, .gsd\code-review\, .gsd\generation-queue\, .gsd\agent-handoff\current-assignment.md
- You NEVER write to: .gsd\research\, source code files

### Project Patterns
- Backend: .NET 8 + Dapper + SQL Server stored procedures only
- Frontend: React 18
- API: Contract-first, API-first
- Compliance: HIPAA, SOC 2, PCI, GDPR
"@

Set-Content -Path "$ClaudeDir\CLAUDE.md" -Value $claudeSettings -Encoding UTF8
Write-Host "   [OK] .claude\CLAUDE.md" -ForegroundColor DarkGreen

Write-Host ""

# ========================================================
# STEP 10: Codex global config (.codex)
# ========================================================

Write-Host "[WRENCH] Configuring Codex global settings..." -ForegroundColor Yellow

$codexInstructions = @"
# Codex - GSD Global Configuration
# Location: $CodexDir\instructions.md
# This file is read by Codex for global context.

## GSD Convergence Engine

When you see references to GSD phases, convergence loops, or health scores,
the global engine is at: $GsdGlobalDir

### Your Role in the Loop
You handle 2 phases (unlimited tokens, execution-heavy):
1. **research**: Deep-read specs, Figma, codebase. Build dependency maps.
2. **execute**: Generate ALL code for the current batch. Full production-ready files.

### Token Freedom
- You have NO token cap. Be thorough.
- Generate COMPLETE files, not snippets
- Include all error handling, logging, validation, documentation
- Read EVERY spec doc and Figma file thoroughly

### Agent Boundaries
- You READ + WRITE source code
- You WRITE to: .gsd\research\, source code, .gsd\agent-handoff\handoff-log.jsonl
- You NEVER write to: .gsd\health\, .gsd\code-review\, .gsd\generation-queue\

### Project Patterns (STRICT)
- Backend: .NET 8 + Dapper (never EF) + SQL Server stored procedures ONLY
- Frontend: React 18 functional components + hooks
- API: Contract-first, RESTful, proper HTTP status codes
- Database: Stored procs only, parameterized, audit columns
- Compliance: HIPAA (encrypt PHI), SOC 2 (RBAC), PCI (tokenize), GDPR (consent)
- Match Figma designs EXACTLY for UI components
"@

Set-Content -Path "$CodexDir\instructions.md" -Value $codexInstructions -Encoding UTF8
Write-Host "   [OK] .codex\instructions.md" -ForegroundColor DarkGreen

Write-Host ""

# ========================================================
# STEP 11: VS Code global user tasks
# ========================================================

Write-Host "Creating VS Code global user tasks..." -ForegroundColor Yellow

# VS Code user-level tasks.json
$vscodeUserDir = Join-Path $env:APPDATA "Code\User"
if (-not (Test-Path $vscodeUserDir)) {
    $vscodeUserDir = Join-Path $env:APPDATA "Code - Insiders\User"
}

if (Test-Path $vscodeUserDir) {
    $userTasksFile = Join-Path $vscodeUserDir "tasks.json"
    $gsdTasks = @{
        version = "2.0.0"
        tasks = @(
            @{
                label = "GSD: Convergence Loop"
                type = "shell"
                command = "powershell"
                args = @("-ExecutionPolicy", "Bypass", "-File", "$GsdGlobalDir\scripts\convergence-loop.ps1")
                presentation = @{ reveal="always"; panel="dedicated"; focus=$false; clear=$true }
                runOptions = @{ instanceLimit = 1 }
                problemMatcher = @()
                group = "build"
            },
            @{
                label = "GSD: Convergence (Dry Run)"
                type = "shell"
                command = "powershell"
                args = @("-ExecutionPolicy", "Bypass", "-File", "$GsdGlobalDir\scripts\convergence-loop.ps1", "-DryRun")
                presentation = @{ reveal="always"; panel="dedicated"; clear=$true }
                problemMatcher = @()
            },
            @{
                label = "GSD: Convergence (Skip Research)"
                type = "shell"
                command = "powershell"
                args = @("-ExecutionPolicy", "Bypass", "-File", "$GsdGlobalDir\scripts\convergence-loop.ps1", "-SkipResearch")
                presentation = @{ reveal="always"; panel="dedicated"; clear=$true }
                runOptions = @{ instanceLimit = 1 }
                problemMatcher = @()
            },
            @{
                label = "GSD: Init Project"
                type = "shell"
                command = "powershell"
                args = @("-ExecutionPolicy", "Bypass", "-File", "$GsdGlobalDir\scripts\convergence-loop.ps1", "-MaxIterations", "0")
                presentation = @{ reveal="always"; panel="shared" }
                problemMatcher = @()
            }
        )
    }

    # Always overwrite VS Code tasks to keep current
        $gsdTasks | ConvertTo-Json -Depth 5 | Set-Content $userTasksFile -Encoding UTF8
        Write-Host "   [OK] VS Code user tasks.json updated" -ForegroundColor DarkGreen
} else {
    Write-Host "   [!!]  VS Code user dir not found. Skipping global tasks." -ForegroundColor DarkYellow
}

Write-Host ""

# ========================================================
# DONE
# ========================================================

Write-Host "=========================================================" -ForegroundColor Green
Write-Host "  [OK] GSD Global Convergence Engine - Installed!" -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  INSTALLED TO:" -ForegroundColor Yellow
Write-Host "    Engine:       ~\.gsd-global\" -ForegroundColor White
Write-Host "    Claude Code:  ~\.claude\CLAUDE.md" -ForegroundColor White
Write-Host "    Codex:        ~\.codex\instructions.md" -ForegroundColor White
Write-Host "    Command:      gsd-converge (after terminal restart)" -ForegroundColor White
Write-Host ""
Write-Host "  AGENT ASSIGNMENT:" -ForegroundColor Yellow
Write-Host "    Claude Code:  code-review, create-phases, plan  (~11K tokens/iter)" -ForegroundColor Cyan
Write-Host "    Codex:        research, execute                 (unlimited tokens)" -ForegroundColor Magenta
Write-Host ""
Write-Host "  HOW TO USE:" -ForegroundColor Yellow
Write-Host "  -------------------------------------------------" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  From ANY repo:" -ForegroundColor White
Write-Host "    cd C:\path\to\any\project" -ForegroundColor Cyan
Write-Host "    gsd-converge                    # full loop" -ForegroundColor Cyan
Write-Host "    gsd-converge -DryRun            # preview only" -ForegroundColor Cyan
Write-Host "    gsd-converge -MaxIterations 5   # limit rounds" -ForegroundColor Cyan
Write-Host "    gsd-converge -SkipResearch      # faster loops" -ForegroundColor Cyan
Write-Host "    gsd-init                        # just init .gsd\" -ForegroundColor Cyan
Write-Host ""
Write-Host "  From VS Code (any project):" -ForegroundColor White
Write-Host "    Ctrl+Shift+P -> 'Run Task' -> 'GSD: Convergence Loop'" -ForegroundColor Cyan
Write-Host ""
Write-Host "  EXPECTED PROJECT STRUCTURE:" -ForegroundColor Yellow
Write-Host "    your-repo\" -ForegroundColor DarkGray
Write-Host "    +-- design\figma\v01\     <- Figma deliverables" -ForegroundColor DarkGray
Write-Host "    +-- design\figma\v02\     <- latest picked automatically" -ForegroundColor DarkGray
Write-Host "    +-- docs\                 <- SDLC specs (Phase A-E)" -ForegroundColor DarkGray
Write-Host "    +-- src\                  <- your code" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  [!!]  RESTART YOUR TERMINAL for 'gsd-converge' command to work" -ForegroundColor Yellow
Write-Host ""
