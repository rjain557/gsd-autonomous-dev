<#
.SYNOPSIS
    GSD Convergence Loop - Bootstrap Setup
    Sets up the .gsd/ folder structure for autonomous Claude Code ? Codex convergence.

.DESCRIPTION
    This script:
    1. Detects the latest Figma design version from \design\figma\v##
    2. References SDLC spec docs from \docs\ (Phase A through Phase E)
    3. Creates the full .gsd/ convergence loop structure
    4. Creates the convergence-loop.ps1 orchestrator
    5. Creates all config, templates, and agent prompt files

.USAGE
    cd C:\path\to\your\repo
    .\setup-gsd-convergence.ps1
#>

param(
    [string]$RepoRoot = (Get-Location).Path
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "  GSD Convergence Loop - Bootstrap Setup" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

# ========================================================
# STEP 1: Validate repo structure
# ========================================================

Write-Host "Repo root: $RepoRoot" -ForegroundColor Yellow

# Check for design\figma\v## folders
$figmaBase = Join-Path $RepoRoot "design\figma"
if (-not (Test-Path $figmaBase)) {
    Write-Host "[XX] design\figma\ not found at $figmaBase" -ForegroundColor Red
    Write-Host "   Expected: design\figma\v01, design\figma\v02, etc." -ForegroundColor Red
    exit 1
}

# Find latest Figma version (highest v## number)
$figmaVersions = Get-ChildItem -Path $figmaBase -Directory |
    Where-Object { $_.Name -match '^v(\d+)$' } |
    Sort-Object { [int]($_.Name -replace '^v', '') } -Descending

if ($figmaVersions.Count -eq 0) {
    Write-Host "[XX] No v## folders found in design\figma\" -ForegroundColor Red
    exit 1
}

$latestFigma = $figmaVersions[0]
$latestFigmaVersion = $latestFigma.Name
$latestFigmaPath = $latestFigma.FullName
$figmaRelPath = "design\figma\$latestFigmaVersion"

Write-Host "[ART] Latest Figma version: $latestFigmaVersion ($latestFigmaPath)" -ForegroundColor Green

# List Figma deliverables
$figmaFiles = Get-ChildItem -Path $latestFigmaPath -Recurse -File
Write-Host "   Found $($figmaFiles.Count) design files:" -ForegroundColor DarkGray
$figmaFiles | Select-Object -First 10 | ForEach-Object {
    Write-Host "   - $($_.Name)" -ForegroundColor DarkGray
}
if ($figmaFiles.Count -gt 10) {
    Write-Host "   ... and $($figmaFiles.Count - 10) more" -ForegroundColor DarkGray
}

# Check for docs\ with SDLC phases
$docsPath = Join-Path $RepoRoot "docs"
if (-not (Test-Path $docsPath)) {
    Write-Host "[XX] docs\ not found at $docsPath" -ForegroundColor Red
    exit 1
}

$sdlcDocs = Get-ChildItem -Path $docsPath -File -Recurse |
    Where-Object { $_.Name -match '(?i)phase' }

Write-Host "[CLIP] SDLC docs found in docs\:" -ForegroundColor Green
$allDocs = Get-ChildItem -Path $docsPath -File -Recurse
$allDocs | ForEach-Object {
    $rel = $_.FullName.Replace($docsPath, "docs")
    Write-Host "   - $rel" -ForegroundColor DarkGray
}

Write-Host ""

# ========================================================
# STEP 2: Create .gsd/ directory structure
# ========================================================

Write-Host "Creating .gsd/ directory structure..." -ForegroundColor Yellow

$gsdRoot = Join-Path $RepoRoot ".gsd"

$directories = @(
    ".gsd",
    ".gsd\health",
    ".gsd\health\history",
    ".gsd\code-review",
    ".gsd\code-review\review-history",
    ".gsd\generation-queue",
    ".gsd\generation-queue\completed",
    ".gsd\agent-handoff",
    ".gsd\phases",
    ".gsd\specs",
    ".gsd\specs\api-contracts",
    ".gsd\specs\data-models",
    ".gsd\config",
    ".gsd\scripts",
    ".gsd\logs",
    ".gsd\prompts"
)

foreach ($dir in $directories) {
    $fullPath = Join-Path $RepoRoot $dir
    if (-not (Test-Path $fullPath)) {
        New-Item -ItemType Directory -Path $fullPath -Force | Out-Null
        Write-Host "   [OK] Created $dir" -ForegroundColor DarkGreen
    } else {
        Write-Host "   [>>]  Exists  $dir" -ForegroundColor DarkGray
    }
}

Write-Host ""

# ========================================================
# STEP 3: Create config files
# ========================================================

Write-Host "[GEAR]  Creating config files..." -ForegroundColor Yellow

# -- loop-config.json --
$loopConfig = @{
    version = "1.0.0"
    target_health = 100
    max_iterations = 20
    stall_threshold = 3
    batch_size_min = 3
    batch_size_max = 8
    figma = @{
        version = $latestFigmaVersion
        path = $figmaRelPath
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
    agents = @{
        reviewer = @{
            name = "claude-code"
            cli = "claude"
            role = "Review, score health, prioritize generation queue"
        }
        developer = @{
            name = "codex"
            cli = "codex"
            approval_mode = "full-auto"
            role = "Generate code to satisfy requirements"
        }
    }
    git = @{
        auto_commit = $true
        tag_on_convergence = $true
        commit_prefix = "gsd-convergence"
    }
} | ConvertTo-Json -Depth 5

Set-Content -Path (Join-Path $gsdRoot "config\loop-config.json") -Value $loopConfig -Encoding UTF8
Write-Host "   [OK] config\loop-config.json" -ForegroundColor DarkGreen

# -- health-current.json (initial state) --
$healthInit = @{
    health_score = 0
    total_requirements = 0
    satisfied = 0
    partial = 0
    not_started = 0
    iteration = 0
    last_agent = "none"
    last_updated = (Get-Date -Format "o")
    figma_version = $latestFigmaVersion
} | ConvertTo-Json -Depth 3

Set-Content -Path (Join-Path $gsdRoot "health\health-current.json") -Value $healthInit -Encoding UTF8
Write-Host "   [OK] health\health-current.json" -ForegroundColor DarkGreen

# -- requirements-matrix.json (empty template) --
$matrixTemplate = @{
    meta = @{
        total_requirements = 0
        satisfied = 0
        partial = 0
        not_started = 0
        health_score = 0
        figma_version = $latestFigmaVersion
        sdlc_phases = @("Phase-A", "Phase-B", "Phase-C", "Phase-D", "Phase-E")
        last_updated = (Get-Date -Format "o")
        iteration = 0
    }
    requirements = @()
} | ConvertTo-Json -Depth 4

Set-Content -Path (Join-Path $gsdRoot "health\requirements-matrix.json") -Value $matrixTemplate -Encoding UTF8
Write-Host "   [OK] health\requirements-matrix.json" -ForegroundColor DarkGreen

Write-Host ""

# ========================================================
# STEP 4: Create Figma mapping template
# ========================================================

Write-Host "[ART] Creating Figma mapping..." -ForegroundColor Yellow

$figmaFileList = $figmaFiles | ForEach-Object {
    $rel = $_.FullName.Replace($latestFigmaPath, "").TrimStart("\")
    "| $rel | | | not_started |"
}

$figmaMapping = @"
# Figma Design Mapping
> Auto-generated from: $figmaRelPath
> Version: $latestFigmaVersion
> Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

## Source
- **Design directory**: ``$figmaRelPath``
- **Version**: $latestFigmaVersion (latest detected at setup time)

## Component Mapping

Map each Figma frame/component to the code file that implements it.
The convergence loop uses this to measure Figma drift.

| Figma File / Frame | React Component Path | Description | Status |
|---|---|---|---|
$($figmaFileList -join "`n")

## Design Tokens

Extract from Figma and document here:

### Colors
| Token | Value | Usage |
|---|---|---|
| --color-primary | #000000 | TBD |
| --color-secondary | #000000 | TBD |

### Typography
| Token | Font | Size | Weight |
|---|---|---|---|
| --font-heading | TBD | TBD | TBD |
| --font-body | TBD | TBD | TBD |

### Spacing
| Token | Value |
|---|---|
| --space-sm | TBD |
| --space-md | TBD |
| --space-lg | TBD |

## Notes
- The convergence loop reads this file to understand what the UI should look like
- Update this mapping as Figma designs evolve
- Both Claude Code and Codex reference this for UI generation
"@

Set-Content -Path (Join-Path $gsdRoot "specs\figma-mapping.md") -Value $figmaMapping -Encoding UTF8
Write-Host "   [OK] specs\figma-mapping.md ($($figmaFiles.Count) design files mapped)" -ForegroundColor DarkGreen

Write-Host ""

# ========================================================
# STEP 5: Create SDLC spec references
# ========================================================

Write-Host "[CLIP] Creating SDLC spec references..." -ForegroundColor Yellow

$sdlcDocsList = $allDocs | ForEach-Object {
    $rel = $_.FullName.Replace($RepoRoot, "").TrimStart("\")
    "- [$($_.Name)]($rel)"
}

$specsReadme = @"
# Specification Documents Reference
> Auto-generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

## SDLC Phase Documents

Source directory: ``docs\``

$($sdlcDocsList -join "`n")

## Phase Mapping

| Phase | Scope | Key Deliverables |
|---|---|---|
| Phase A | Discovery & Intake | Requirements, stakeholder needs, constraints |
| Phase B | Architecture & Design | System design, API contracts, data models |
| Phase C | Implementation Planning | Task breakdown, sprint planning, dependencies |
| Phase D | Implementation | Code generation, testing, integration |
| Phase E | Deployment & Delivery | Release, monitoring, documentation |

## How the Convergence Loop Uses These

1. **Phase 0 (Init)**: Claude Code reads ALL docs to build the requirements matrix
2. **Each iteration**: Claude Code reviews code against spec requirements
3. **Generation**: Codex reads specs to understand what code to produce
4. **Verification**: Claude Code verifies generated code satisfies spec requirements

## Notes
- These docs are the SOURCE OF TRUTH for what the system should do
- Figma designs are the SOURCE OF TRUTH for what the system should look like
- The convergence loop drives the codebase to satisfy BOTH
"@

Set-Content -Path (Join-Path $gsdRoot "specs\sdlc-reference.md") -Value $specsReadme -Encoding UTF8
Write-Host "   [OK] specs\sdlc-reference.md" -ForegroundColor DarkGreen

Write-Host ""

# ========================================================
# STEP 6: Create GSD phase definitions for agents
# ========================================================

Write-Host "[BOOK] Creating GSD phase definitions..." -ForegroundColor Yellow

$gsdSkillReadme = @"
# GSD Skill - Convergence Loop

This folder contains the GSD (Get Stuff Done) skill definitions used by both
Claude Code and Codex in the autonomous convergence loop.

## How This Works

Two AI agents share this ``.gsd/`` folder as a communication bus:

- **Claude Code** = Reviewer & Architect (reads code, scores health, prioritizes work)
- **Codex** = Developer (generates code to satisfy requirements)

The loop runs until the repository reaches 100% health against:
1. SDLC specification documents (``docs\``)
2. Figma design deliverables (``$figmaRelPath``)

## Folder Structure

```
.gsd/
+-- health/                  # Health score tracking
|   +-- health-current.json  # Current score + breakdown
|   +-- health-history.jsonl # Score over time
|   +-- requirements-matrix.json # Every requirement + status
|   +-- drift-report.md      # Human-readable gap analysis
+-- code-review/             # Claude Code writes review findings here
+-- generation-queue/        # Prioritized list of what to build next
+-- agent-handoff/           # Communication between agents
+-- phases/                  # GSD phase definitions (this folder)
+-- specs/                   # Links to spec docs + Figma mapping
+-- config/                  # Loop configuration
+-- prompts/                 # Agent prompt templates
+-- scripts/                 # Orchestrator scripts
+-- logs/                    # Execution logs
```

## Agent Boundaries

| | Claude Code (Reviewer) | Codex (Developer) |
|---|---|---|
| **Reads** | Full repo, .gsd/phases/, specs/ | .gsd/code-review/, phases/, specs/, agent-handoff/ |
| **Writes** | code-review/*, health/*, generation-queue/*, agent-handoff/current-assignment.md | Source code only, agent-handoff/handoff-log.jsonl |
| **Never touches** | Source code | code-review/*, health/* |
"@

Set-Content -Path (Join-Path $gsdRoot "phases\README.md") -Value $gsdSkillReadme -Encoding UTF8
Write-Host "   [OK] phases\README.md" -ForegroundColor DarkGreen

# -- Phase definitions --
$phaseReview = @"
# GSD Phase: Code Review

## Trigger
``/gsd:code-review``

## Agent
Claude Code (Reviewer)

## Inputs
- Full repository source code
- ``.gsd/health/requirements-matrix.json``
- ``.gsd/specs/`` (SDLC docs reference + Figma mapping)
- ``$figmaRelPath`` (latest Figma deliverables)
- ``docs\`` (SDLC specification documents Phase A-E)

## Process

### 1. Requirements Scan
For each requirement in the matrix:
- Check if the codebase contains code that satisfies it
- Verify against the spec doc that defines it
- For Figma requirements, verify component matches design
- Update status: satisfied | partial | not_started

### 2. Health Score Calculation
``health_score = (satisfied_count / total_requirements) * 100``

### 3. Drift Analysis
Identify the top gaps:
- Spec drift: business logic, API contracts, data models not yet implemented
- Figma drift: UI components not matching design
- Phase drift: GSD phase deliverables missing
- Quality drift: patterns, compliance, error handling gaps

### 4. Generation Queue
Select next batch of 3-8 requirements to implement:
- Respect dependency order
- Follow SDLC phase sequence (A -> B -> C -> D -> E)
- Group related requirements
- Prioritize foundation (models, APIs) before UI

## Outputs
- ``.gsd/health/health-current.json`` (updated score)
- ``.gsd/health/health-history.jsonl`` (append score entry)
- ``.gsd/health/requirements-matrix.json`` (updated statuses)
- ``.gsd/health/drift-report.md`` (human-readable gaps)
- ``.gsd/generation-queue/queue-current.json`` (next batch)
- ``.gsd/agent-handoff/current-assignment.md`` (instructions for Codex)
- ``.gsd/code-review/review-current.md`` (detailed findings)
"@

Set-Content -Path (Join-Path $gsdRoot "phases\phase-code-review.md") -Value $phaseReview -Encoding UTF8
Write-Host "   [OK] phases\phase-code-review.md" -ForegroundColor DarkGreen

$phaseGenerate = @"
# GSD Phase: Code Generation

## Trigger
Called by convergence loop after code review

## Agent
Codex (Developer)

## Inputs
- ``.gsd/agent-handoff/current-assignment.md`` (specific instructions)
- ``.gsd/generation-queue/queue-current.json`` (prioritized batch)
- ``.gsd/health/requirements-matrix.json`` (full context)
- ``.gsd/specs/`` (SDLC docs reference + Figma mapping)
- ``$figmaRelPath`` (latest Figma deliverables)
- ``docs\`` (SDLC specification documents Phase A-E)

## Project Patterns (MUST follow)

### Backend
- .NET 8 with Dapper for data access
- SQL Server with stored procedures ONLY (no inline SQL, no EF)
- API-first, contract-first development
- RESTful endpoints with proper HTTP status codes
- Input validation on all endpoints
- Structured logging

### Frontend
- React 18 functional components with hooks
- Match Figma designs exactly (spacing, colors, typography)
- Responsive breakpoints as defined in Figma
- Accessibility (ARIA labels, keyboard navigation)

### Database
- All data access through stored procedures
- Parameterized queries (no string concatenation)
- Proper indexing for query patterns
- Migration scripts for schema changes

### Compliance
- HIPAA: PHI encryption at rest and in transit, audit logging
- SOC 2: Access controls, change management
- PCI: Card data handling, tokenization
- GDPR: Consent management, data deletion

## Process

### 1. Read Assignment
Parse current-assignment.md for specific file-level instructions.

### 2. Generate Code
For each requirement in the batch:
- Create/modify files as specified
- Follow project patterns strictly
- Include error handling and input validation
- Add inline documentation

### 3. Self-Verify
After generation, confirm:
- Files compile / have no syntax errors
- Required patterns are followed
- Figma components match design references
- API contracts match spec

## Outputs
- Source code files (created/modified)
- Append summary to ``.gsd/agent-handoff/handoff-log.jsonl``

## Boundaries
- DO NOT modify anything in ``.gsd/code-review/``
- DO NOT modify anything in ``.gsd/health/``
- DO NOT modify anything in ``.gsd/generation-queue/``
- ONLY write source code and handoff log entries
"@

Set-Content -Path (Join-Path $gsdRoot "phases\phase-code-generation.md") -Value $phaseGenerate -Encoding UTF8
Write-Host "   [OK] phases\phase-code-generation.md" -ForegroundColor DarkGreen

Write-Host ""

# ========================================================
# STEP 7: Create agent prompt templates
# ========================================================

Write-Host "Creating agent prompt templates..." -ForegroundColor Yellow

# -- Phase 0: Init prompt --
$promptInit = @"
You have the GSD skill in .gsd/. This is PHASE 0 - initial requirements extraction.

YOUR JOB: Build the complete requirements matrix from all specification documents and Figma designs.

## Sources to Read

### SDLC Specifications (Source of Truth for BEHAVIOR)
Read every file in: docs\
These contain Phase A through Phase E specifications defining what the system must do.

### Figma Designs (Source of Truth for UI)
Read the mapping: .gsd\specs\figma-mapping.md
Design files are in: $figmaRelPath
These define what the system must look like.

### Existing Code
Scan the full repository to determine what has already been implemented.

## What to Extract

For EVERY discrete requirement, create an entry:
- id: REQ-NNN (sequential)
- source: "spec" | "figma" | "compliance"
- sdlc_phase: "Phase-A" | "Phase-B" | "Phase-C" | "Phase-D" | "Phase-E"
- description: What must be true for this requirement to be satisfied
- figma_frame: (if UI) the Figma file/frame reference
- spec_doc: which doc in docs\ defines this requirement
- status: "satisfied" | "partial" | "not_started" (based on current codebase scan)
- satisfied_by: list of existing files that implement this (if any)
- depends_on: other REQ ids this depends on
- pattern: "api-endpoint" | "stored-procedure" | "react-component" | "data-model" | "business-logic" | "compliance" | "config"
- priority: "critical" | "high" | "medium" | "low"

## Requirements Categories to Extract
- API endpoints defined in specs
- Database tables and stored procedures
- React UI components from Figma
- Business logic rules
- Authentication / authorization flows
- Data validation rules
- Compliance requirements (HIPAA, SOC 2, PCI, GDPR)
- Error handling patterns
- Configuration and environment setup

## Output Files
1. .gsd\health\requirements-matrix.json - full matrix with all requirements
2. .gsd\health\health-current.json - calculated health score
3. .gsd\health\drift-report.md - human-readable analysis of gaps
4. .gsd\specs\figma-mapping.md - update with component-to-code mappings

Be THOROUGH. Every requirement you miss will not get built.
"@

Set-Content -Path (Join-Path $gsdRoot "prompts\phase0-init.md") -Value $promptInit -Encoding UTF8
Write-Host "   [OK] prompts\phase0-init.md" -ForegroundColor DarkGreen

# -- Review prompt template --
$promptReview = @"
You have the GSD skill in .gsd/. Iteration {{ITERATION}}. Health: {{HEALTH}}%. Target: 100%.

Read the phase definition: .gsd\phases\phase-code-review.md

## STEP 1 - REVIEW
Read .gsd\health\requirements-matrix.json
Scan the current codebase against ALL requirements.
Cross-reference with:
  - docs\ (SDLC specs Phase A-E)
  - $figmaRelPath (latest Figma designs)
  - .gsd\specs\figma-mapping.md (component mapping)
Update each requirement status: satisfied | partial | not_started
Update satisfied_by file lists.

## STEP 2 - SCORE
Recalculate: health_score = (satisfied / total) * 100
Write to: .gsd\health\health-current.json
Append to: .gsd\health\health-history.jsonl
Update: .gsd\health\drift-report.md

## STEP 3 - PRIORITIZE
Select next batch of 3-8 unsatisfied requirements.
Priority order:
  1. Dependencies first (foundations before features)
  2. SDLC phase order (A -> B -> C -> D -> E)
  3. Spec before Figma (backend before frontend)
  4. Group related requirements
Write to: .gsd\generation-queue\queue-current.json

## STEP 4 - HANDOFF
Write detailed generation instructions to: .gsd\agent-handoff\current-assignment.md
Include: exact file paths, patterns to follow, Figma references, acceptance criteria.

If iteration > 1, focus review ONLY on files changed since last iteration.
If health = 100, set status to "passed" in health-current.json.
"@

Set-Content -Path (Join-Path $gsdRoot "prompts\review-prompt-template.md") -Value $promptReview -Encoding UTF8
Write-Host "   [OK] prompts\review-prompt-template.md" -ForegroundColor DarkGreen

# -- Generate prompt template --
$promptGenerate = @"
You have the GSD skill in .gsd/. Health: {{HEALTH}}%. Your job: INCREASE it toward 100%.

Read the phase definition: .gsd\phases\phase-code-generation.md

## READ THESE FILES
1. .gsd\agent-handoff\current-assignment.md - your detailed instructions
2. .gsd\generation-queue\queue-current.json - the prioritized batch
3. .gsd\health\requirements-matrix.json - full requirements context
4. .gsd\specs\sdlc-reference.md - links to spec docs
5. .gsd\specs\figma-mapping.md - Figma component mapping
6. docs\ - SDLC specification documents (Phase A-E)
7. $figmaRelPath - latest Figma design deliverables

## GENERATE CODE
Implement EVERY requirement in the current batch.
Follow project patterns strictly:
  - .NET 8 with Dapper for data access
  - SQL Server stored procedures only (no inline SQL)
  - React 18 for frontend components
  - API-first, contract-first approach
  - HIPAA/SOC 2/PCI/GDPR compliance patterns

Create complete, production-ready files with:
  - Error handling and structured logging
  - Input validation
  - Inline documentation
  - Match Figma designs exactly for UI components

## BOUNDARIES
DO NOT modify anything in .gsd\code-review\
DO NOT modify anything in .gsd\health\
DO NOT modify anything in .gsd\generation-queue\
ONLY write source code and append to .gsd\agent-handoff\handoff-log.jsonl
"@

Set-Content -Path (Join-Path $gsdRoot "prompts\generate-prompt-template.md") -Value $promptGenerate -Encoding UTF8
Write-Host "   [OK] prompts\generate-prompt-template.md" -ForegroundColor DarkGreen

Write-Host ""

# ========================================================
# STEP 8: Create the main convergence loop script
# ========================================================

Write-Host "[SYNC] Creating convergence-loop.ps1..." -ForegroundColor Yellow

$convergenceScript = @'
<#
.SYNOPSIS
    GSD Convergence Loop - Autonomous Claude Code + Codex orchestrator.
    Drives repository to 100% health against spec documents and Figma designs.

.USAGE
    cd C:\path\to\your\repo
    .\.gsd\scripts\convergence-loop.ps1
    .\.gsd\scripts\convergence-loop.ps1 -MaxIterations 10
    .\.gsd\scripts\convergence-loop.ps1 -SkipInit
#>

param(
    [int]$MaxIterations = 20,
    [int]$StallThreshold = 3,
    [switch]$SkipInit,
    [switch]$DryRun
)

$ErrorActionPreference = "Continue"
$RepoRoot = (Get-Location).Path
$GsdDir = Join-Path $RepoRoot ".gsd"
$HealthFile = Join-Path $GsdDir "health\health-current.json"
$HealthLog = Join-Path $GsdDir "health\health-history.jsonl"
$MatrixFile = Join-Path $GsdDir "health\requirements-matrix.json"
$HandoffLog = Join-Path $GsdDir "agent-handoff\handoff-log.jsonl"

$Iteration = 0
$Health = 0
$StallCount = 0
$TargetHealth = 100

# -- Detect latest Figma version --
$figmaBase = Join-Path $RepoRoot "design\figma"
$latestFigma = Get-ChildItem -Path $figmaBase -Directory |
    Where-Object { $_.Name -match '^v(\d+)$' } |
    Sort-Object { [int]($_.Name -replace '^v', '') } -Descending |
    Select-Object -First 1

$FigmaVersion = $latestFigma.Name
$FigmaPath = "design\figma\$FigmaVersion"

# -- Helper functions --
function Get-Health {
    try {
        $json = Get-Content $HealthFile -Raw | ConvertFrom-Json
        return [double]$json.health_score
    } catch { return 0 }
}

function Log-Handoff($agent, $action, $iter, $health) {
    $entry = @{
        agent = $agent
        action = $action
        iteration = $iter
        health = $health
        figma_version = $FigmaVersion
        timestamp = (Get-Date -Format "o")
    } | ConvertTo-Json -Compress
    Add-Content -Path $HandoffLog -Value $entry -Encoding UTF8
}

function Build-ReviewPrompt($iter, $health) {
    $template = Get-Content (Join-Path $GsdDir "prompts\review-prompt-template.md") -Raw
    return $template.Replace("{{ITERATION}}", "$iter").Replace("{{HEALTH}}", "$health")
}

function Build-GeneratePrompt($health) {
    $template = Get-Content (Join-Path $GsdDir "prompts\generate-prompt-template.md") -Raw
    return $template.Replace("{{HEALTH}}", "$health")
}

# -- Start --
Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "  GSD Convergence Loop" -ForegroundColor Cyan
Write-Host "  Target: ${TargetHealth}% health" -ForegroundColor Cyan
Write-Host "  Max iterations: $MaxIterations" -ForegroundColor Cyan
Write-Host "  Figma: $FigmaVersion ($FigmaPath)" -ForegroundColor Cyan
Write-Host "  Stall threshold: $StallThreshold" -ForegroundColor Cyan
if ($DryRun) { Write-Host "  [!!]  DRY RUN MODE - no agents will execute" -ForegroundColor Yellow }
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

# ========================================================
# PHASE 0: Initial Requirements Extraction
# ========================================================
$matrixContent = Get-Content $MatrixFile -Raw | ConvertFrom-Json
$hasRequirements = $matrixContent.requirements.Count -gt 0

if (-not $hasRequirements -and -not $SkipInit) {
    Write-Host "[CLIP] Phase 0: Building requirements matrix..." -ForegroundColor Magenta
    Write-Host "   This runs once to extract all requirements from specs + Figma." -ForegroundColor DarkGray
    Log-Handoff "claude-code" "init-matrix" 0 0

    $initPrompt = Get-Content (Join-Path $GsdDir "prompts\phase0-init.md") -Raw

    if (-not $DryRun) {
        claude -p $initPrompt `
            --allowedTools "Read,Write,Edit,Bash,mcp__*" `
            2>&1 | Tee-Object (Join-Path $GsdDir "logs\phase0-init.log")
    } else {
        Write-Host "   [DRY RUN] Would execute: claude -p <phase0-init prompt>" -ForegroundColor DarkYellow
    }

    $Health = Get-Health
    Log-Handoff "system" "init-complete" 0 $Health
    Write-Host "[OK] Requirements matrix built. Initial health: ${Health}%" -ForegroundColor Green
    Write-Host ""
} elseif ($SkipInit) {
    Write-Host "[>>]  Skipping Phase 0 (--SkipInit)" -ForegroundColor DarkGray
    $Health = Get-Health
} else {
    Write-Host "[>>]  Requirements matrix already populated ($($matrixContent.requirements.Count) requirements)" -ForegroundColor DarkGray
    $Health = Get-Health
}

Write-Host "[CHART] Starting health: ${Health}%" -ForegroundColor Yellow
Write-Host ""

# ========================================================
# MAIN CONVERGENCE LOOP
# ========================================================
while ($Health -lt $TargetHealth -and $Iteration -lt $MaxIterations -and $StallCount -lt $StallThreshold) {
    $Iteration++
    $PrevHealth = $Health

    Write-Host "=== Iteration $Iteration / $MaxIterations | Health: ${Health}% -> ${TargetHealth}% ===" -ForegroundColor White

    # -- STEP A: Claude Code - Review + Prioritize --
    Write-Host "[SEARCH] [$Iteration] Claude Code -> Code Review + Prioritize" -ForegroundColor Cyan
    Log-Handoff "claude-code" "review-prioritize" $Iteration $Health

    $reviewPrompt = Build-ReviewPrompt $Iteration $Health

    if (-not $DryRun) {
        claude -p $reviewPrompt `
            --allowedTools "Read,Write,Edit,Bash,mcp__*" `
            2>&1 | Tee-Object (Join-Path $GsdDir "logs\claude-review-$Iteration.log")
    } else {
        Write-Host "   [DRY RUN] Would execute: claude -p <review prompt iter $Iteration>" -ForegroundColor DarkYellow
    }

    $Health = Get-Health
    Write-Host "[CHART] [$Iteration] Post-review health: ${Health}%" -ForegroundColor Yellow

    # Check if converged
    if ($Health -ge $TargetHealth) {
        Write-Host "[OK] Health target reached during review!" -ForegroundColor Green
        Log-Handoff "system" "converged" $Iteration $Health
        break
    }

    # -- STEP B: Codex - Generate Code --
    Write-Host "[WRENCH] [$Iteration] Codex -> Auto-develop" -ForegroundColor Magenta
    Log-Handoff "codex" "generate" $Iteration $Health

    $generatePrompt = Build-GeneratePrompt $Health

    if (-not $DryRun) {
        codex --approval-mode full-auto `
              --quiet `
              $generatePrompt `
              2>&1 | Tee-Object (Join-Path $GsdDir "logs\codex-generate-$Iteration.log")

        # Git commit
        git add -A
        git commit -m "gsd-convergence: iter $Iteration codex generation (health: ${Health}%)" --no-verify 2>$null
    } else {
        Write-Host "   [DRY RUN] Would execute: codex --approval-mode full-auto <generate prompt>" -ForegroundColor DarkYellow
    }

    # -- Stall detection --
    $NewHealth = Get-Health
    if ($NewHealth -le $PrevHealth) {
        $StallCount++
        Write-Host "[!!]  [$Iteration] No progress (${PrevHealth}% -> ${NewHealth}%). Stall: $StallCount/$StallThreshold" -ForegroundColor DarkYellow

        if ($StallCount -ge $StallThreshold) {
            Write-Host "[STOP] Stall threshold reached. Running diagnosis..." -ForegroundColor Red
            Log-Handoff "claude-code" "stall-diagnosis" $Iteration $NewHealth

            if (-not $DryRun) {
                $stallPrompt = @"
The convergence loop has stalled for $StallCount iterations at ${NewHealth}% health.
Read .gsd\health\health-history.jsonl and .gsd\health\drift-report.md and .gsd\health\requirements-matrix.json.
Diagnose WHY progress stalled. Common causes:
  - Circular dependencies
  - Requirements that can't be verified
  - Codex code not meeting requirement criteria
  - Spec ambiguity
  - Figma mapping gaps
Write diagnosis to .gsd\health\stall-diagnosis.md with recommended actions.
"@
                claude -p $stallPrompt `
                    --allowedTools "Read,Write,Bash" `
                    2>&1 | Tee-Object (Join-Path $GsdDir "logs\stall-diagnosis-$Iteration.log")
            }
            break
        }
    } else {
        $StallCount = 0
    }

    $Health = $NewHealth
    Write-Host "[SYNC] [$Iteration] Done. Health: ${Health}%" -ForegroundColor Cyan
    Write-Host ""
    Start-Sleep -Seconds 2
}

# ========================================================
# FINAL REPORT
# ========================================================
Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
$FinalHealth = Get-Health

if ($FinalHealth -ge $TargetHealth) {
    Write-Host "[PARTY] CONVERGENCE ACHIEVED" -ForegroundColor Green
    Write-Host "   Health: ${FinalHealth}%" -ForegroundColor Green
    Write-Host "   Iterations: $Iteration" -ForegroundColor Green
    Write-Host "   Figma: $FigmaVersion" -ForegroundColor Green
    if (-not $DryRun) {
        git add -A
        git commit -m "gsd-convergence: COMPLETE - 100% health in $Iteration iterations" --no-verify 2>$null
        git tag "gsd-converged-$(Get-Date -Format 'yyyyMMdd-HHmmss')" 2>$null
    }
} elseif ($StallCount -ge $StallThreshold) {
    Write-Host "[STOP] STALLED at ${FinalHealth}%" -ForegroundColor Red
    Write-Host "   See: .gsd\health\stall-diagnosis.md" -ForegroundColor Red
} else {
    Write-Host "[!!]  MAX ITERATIONS at ${FinalHealth}%" -ForegroundColor Yellow
    Write-Host "   Remaining: .gsd\health\drift-report.md" -ForegroundColor Yellow
}

Write-Host "   Matrix: .gsd\health\requirements-matrix.json" -ForegroundColor DarkGray
Write-Host "   History: .gsd\health\health-history.jsonl" -ForegroundColor DarkGray
Write-Host "   Logs: .gsd\logs\" -ForegroundColor DarkGray
Write-Host "==============================================" -ForegroundColor Cyan
'@

Set-Content -Path (Join-Path $gsdRoot "scripts\convergence-loop.ps1") -Value $convergenceScript -Encoding UTF8
Write-Host "   [OK] scripts\convergence-loop.ps1" -ForegroundColor DarkGreen

Write-Host ""

# ========================================================
# STEP 9: Create VS Code task
# ========================================================

Write-Host "[WRENCH] Creating VS Code task configuration..." -ForegroundColor Yellow

$vscodeDir = Join-Path $RepoRoot ".vscode"
if (-not (Test-Path $vscodeDir)) {
    New-Item -ItemType Directory -Path $vscodeDir -Force | Out-Null
}

$tasksFile = Join-Path $vscodeDir "tasks.json"
$tasksConfig = @{
    version = "2.0.0"
    tasks = @(
        @{
            label = "GSD: Convergence Loop"
            type = "shell"
            command = "powershell"
            args = @("-ExecutionPolicy", "Bypass", "-File", ".gsd\scripts\convergence-loop.ps1")
            presentation = @{
                reveal = "always"
                panel = "dedicated"
                focus = $false
                clear = $true
            }
            runOptions = @{ instanceLimit = 1 }
            problemMatcher = @()
            group = "build"
        },
        @{
            label = "GSD: Convergence Loop (Dry Run)"
            type = "shell"
            command = "powershell"
            args = @("-ExecutionPolicy", "Bypass", "-File", ".gsd\scripts\convergence-loop.ps1", "-DryRun")
            presentation = @{
                reveal = "always"
                panel = "dedicated"
                focus = $false
                clear = $true
            }
            problemMatcher = @()
        },
        @{
            label = "GSD: Review Only (Claude Code)"
            type = "shell"
            command = "claude"
            args = @("-p", "Read .gsd\prompts\review-prompt-template.md and execute the code review phase. Current iteration: 1.")
            presentation = @{
                reveal = "always"
                panel = "dedicated"
            }
            problemMatcher = @()
        }
    )
} | ConvertTo-Json -Depth 5

# Only write if tasks.json doesn't exist (don't overwrite)
if (-not (Test-Path $tasksFile)) {
    Set-Content -Path $tasksFile -Value $tasksConfig -Encoding UTF8
    Write-Host "   [OK] .vscode\tasks.json (created)" -ForegroundColor DarkGreen
} else {
    $backupTasksFile = Join-Path $vscodeDir "tasks.gsd-backup.json"
    Set-Content -Path $backupTasksFile -Value $tasksConfig -Encoding UTF8
    Write-Host "   [!!]  .vscode\tasks.json already exists" -ForegroundColor DarkYellow
    Write-Host "   [OK] Saved GSD tasks to .vscode\tasks.gsd-backup.json - merge manually" -ForegroundColor DarkGreen
}

Write-Host ""

# ========================================================
# STEP 10: Create .gitignore entries
# ========================================================

Write-Host "[MEMO] Updating .gitignore..." -ForegroundColor Yellow

$gitignorePath = Join-Path $RepoRoot ".gitignore"
$gsdIgnore = @"

# GSD Convergence Loop - transient files
.gsd/logs/
.gsd/agent-handoff/handoff-log.jsonl
"@

if (Test-Path $gitignorePath) {
    $existing = Get-Content $gitignorePath -Raw
    if ($existing -notmatch "GSD Convergence") {
        Add-Content -Path $gitignorePath -Value $gsdIgnore -Encoding UTF8
        Write-Host "   [OK] Added .gsd entries to .gitignore" -ForegroundColor DarkGreen
    } else {
        Write-Host "   [>>]  .gitignore already has GSD entries" -ForegroundColor DarkGray
    }
} else {
    Set-Content -Path $gitignorePath -Value $gsdIgnore.TrimStart() -Encoding UTF8
    Write-Host "   [OK] Created .gitignore with GSD entries" -ForegroundColor DarkGreen
}

Write-Host ""

# ========================================================
# DONE
# ========================================================

Write-Host "==============================================" -ForegroundColor Green
Write-Host "  [OK] GSD Convergence Loop - Setup Complete!" -ForegroundColor Green
Write-Host "==============================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Structure created:  .gsd\" -ForegroundColor White
Write-Host "  [ART] Figma version:      $FigmaVersion ($FigmaPath)" -ForegroundColor White
Write-Host "  [CLIP] SDLC docs:          docs\ (Phase A-E)" -ForegroundColor White
Write-Host ""
Write-Host "  HOW TO RUN:" -ForegroundColor Yellow
Write-Host "  -----------------------------------------" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Option 1 - Terminal:" -ForegroundColor White
Write-Host "    .\.gsd\scripts\convergence-loop.ps1" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Option 2 - Dry run first:" -ForegroundColor White
Write-Host "    .\.gsd\scripts\convergence-loop.ps1 -DryRun" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Option 3 - VS Code Task:" -ForegroundColor White
Write-Host "    Ctrl+Shift+P -> 'Run Task' -> 'GSD: Convergence Loop'" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Option 4 - Custom iterations:" -ForegroundColor White
Write-Host "    .\.gsd\scripts\convergence-loop.ps1 -MaxIterations 10" -ForegroundColor Cyan
Write-Host ""
Write-Host "  NEXT STEPS:" -ForegroundColor Yellow
Write-Host "  1. Review .gsd\specs\figma-mapping.md and fill in component mappings" -ForegroundColor White
Write-Host "  2. Verify .gsd\config\loop-config.json settings" -ForegroundColor White
Write-Host "  3. Run with -DryRun first to validate setup" -ForegroundColor White
Write-Host "  4. Run the loop: .\.gsd\scripts\convergence-loop.ps1" -ForegroundColor White
Write-Host ""
