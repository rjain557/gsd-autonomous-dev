<#
.SYNOPSIS
    Blueprint Pipeline - Global Installer
    Spec + Figma -> Blueprint -> Code generation pipeline.
    Installs alongside the GSD Convergence Engine as a second capability.

.DESCRIPTION
    TWO GLOBAL CAPABILITIES after installing both:

    gsd-converge    -> 5-phase loop (review, create-phases, research, plan, execute)
                      Best for: ongoing maintenance, existing codebases, iterative fixes
    
    gsd-blueprint   -> 3-phase pipeline (blueprint, build, verify)
                      Best for: greenfield generation, spec-to-code, Figma-to-code

    Installs to:
      C:\Users\rjain\.gsd-global\blueprint\     - blueprint engine
      C:\Users\rjain\.claude\                    - updated with blueprint role
      C:\Users\rjain\.codex\                     - updated with blueprint role

    Token budget comparison per iteration:
      GSD Converge:   ~11K Claude Code + ~65K Codex  (5 agent calls)
      Blueprint:       ~5K Claude Code + ~80K Codex  (2 agent calls after init)

.USAGE
    # Install (one time, run from anywhere)
    powershell -ExecutionPolicy Bypass -File install-gsd-blueprint.ps1

    # Then in any repo:
    gsd-blueprint                       # full pipeline
    gsd-blueprint -DryRun               # preview
    gsd-blueprint -BlueprintOnly        # just generate blueprint, don't build
    gsd-blueprint -BuildOnly            # resume building from existing blueprint
    gsd-blueprint -MaxIterations 10     # limit build/verify cycles
#>

param(
    [string]$UserHome = $env:USERPROFILE
)

$ErrorActionPreference = "Stop"

$GsdGlobalDir = Join-Path $UserHome ".gsd-global"
$BlueprintDir = Join-Path $GsdGlobalDir "blueprint"
$ClaudeDir    = Join-Path $UserHome ".claude"
$CodexDir     = Join-Path $UserHome ".codex"

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  Blueprint Pipeline - Global Installer" -ForegroundColor Cyan
Write-Host "  Companion to GSD Convergence Engine" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

# ========================================================
# STEP 1: Create directory structure
# ========================================================

Write-Host "Creating blueprint directories..." -ForegroundColor Yellow

$directories = @(
    $BlueprintDir,
    "$BlueprintDir\prompts",
    "$BlueprintDir\prompts\claude",
    "$BlueprintDir\prompts\codex",
    "$BlueprintDir\config",
    "$BlueprintDir\scripts",
    "$BlueprintDir\templates"
)

# Ensure parent dirs exist too
if (-not (Test-Path $GsdGlobalDir)) {
    New-Item -ItemType Directory -Path $GsdGlobalDir -Force | Out-Null
}
if (-not (Test-Path "$GsdGlobalDir\bin")) {
    New-Item -ItemType Directory -Path "$GsdGlobalDir\bin" -Force | Out-Null
}
if (-not (Test-Path "$GsdGlobalDir\scripts")) {
    New-Item -ItemType Directory -Path "$GsdGlobalDir\scripts" -Force | Out-Null
}
if (-not (Test-Path $ClaudeDir)) {
    New-Item -ItemType Directory -Path $ClaudeDir -Force | Out-Null
}
if (-not (Test-Path $CodexDir)) {
    New-Item -ItemType Directory -Path $CodexDir -Force | Out-Null
}

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
# STEP 2: Blueprint config
# ========================================================

Write-Host "[GEAR]  Creating blueprint configuration..." -ForegroundColor Yellow

$bpConfig = @{
    version = "1.0.0"
    engine = "blueprint-pipeline"
    description = "3-phase spec-to-code pipeline: blueprint -> build -> verify"
    phases = [ordered]@{
        blueprint = @{
            agent = "claude-code"
            runs = "once (re-run on spec/Figma change)"
            description = "Read ALL specs + Figma. Produce complete file-by-file build manifest."
            estimated_tokens = "4000-6000"
        }
        build = @{
            agent = "codex"
            runs = "iterative (batches of 10-20 blueprint items)"
            description = "Generate code for the next batch from blueprint. Complete production-ready files."
            estimated_tokens = "50000-100000+ (unlimited)"
        }
        verify = @{
            agent = "claude-code"
            runs = "after each build iteration"
            description = "Diff what exists vs blueprint. Score completeness. Binary pass/fail per item."
            estimated_tokens = "1500-3000"
        }
    }
    token_budget = @{
        claude_per_iteration = "~2K-3K (verify only, after initial blueprint)"
        codex_per_iteration = "~50K-100K+ (unlimited)"
        claude_monthly_at_20_iters = "~50K-60K + 5K blueprint = ~65K total"
        comparison = "~3x more token-efficient than GSD 5-phase loop"
    }
    defaults = @{
        max_iterations = 30
        stall_threshold = 3
        batch_size = 15
        target_health = 100
    }
    project_structure = @{
        figma_path = "design\figma"
        figma_version_pattern = "^v(\d+)$"
        sdlc_docs_path = "docs"
        blueprint_file = ".gsd\blueprint\blueprint.json"
        state_dir = ".gsd\blueprint"
    }
    patterns = @{
        backend = ".NET 8 with Dapper"
        database = "SQL Server stored procedures only"
        frontend = "React 18"
        api = "Contract-first, API-first"
        compliance = @("HIPAA", "SOC 2", "PCI", "GDPR")
    }
} | ConvertTo-Json -Depth 5

Set-Content -Path "$BlueprintDir\config\blueprint-config.json" -Value $bpConfig -Encoding UTF8
Write-Host "   [OK] config\blueprint-config.json" -ForegroundColor DarkGreen

Write-Host ""

# ========================================================
# STEP 3: Claude prompts (blueprint + verify)
# ========================================================

Write-Host "[SEARCH] Creating Claude Code prompts (blueprint, verify)..." -ForegroundColor Yellow

# -- PHASE 1: BLUEPRINT (Claude Code - one time) --
$claudeBlueprint = @'
# Blueprint Phase - Claude Code
# ONE-TIME: Read all specs + Figma -> produce complete build manifest

You are the ARCHITECT. Your SINGLE job: produce blueprint.json - a complete
file-by-file manifest of every file this project needs, in exact build order.

## Context
- Project: {{REPO_ROOT}}
- Figma: {{FIGMA_PATH}} (version {{FIGMA_VERSION}})
- SDLC docs: docs\ (Phase A through Phase E)
- Output: {{GSD_DIR}}\blueprint\blueprint.json

## Read THOROUGHLY
1. EVERY file in docs\ - read each one completely, extract every requirement
2. EVERY file in {{FIGMA_PATH}} - understand every screen, component, state
3. Existing codebase - scan what already exists (if anything)

## Produce blueprint.json

```json
{
  "project": "<project name from specs>",
  "figma_version": "{{FIGMA_VERSION}}",
  "generated": "<timestamp>",
  "total_items": <N>,
  "tiers": [
    {
      "tier": 1,
      "name": "Database Foundation",
      "description": "Tables, migrations, base stored procedures",
      "items": [
        {
          "id": 1,
          "path": "src/Database/Migrations/V001__CreateUserTables.sql",
          "type": "migration",
          "spec_source": "docs/Phase-B-DataModel.md#users",
          "figma_frame": null,
          "description": "User, Role, UserRole tables with audit columns",
          "depends_on": [],
          "status": "not_started",
          "acceptance": [
            "Tables User, Role, UserRole exist",
            "All tables have CreatedAt, CreatedBy, ModifiedAt, ModifiedBy",
            "Primary keys and foreign keys defined",
            "Indexes on lookup columns"
          ],
          "pattern": "sql-migration"
        }
      ]
    },
    {
      "tier": 2,
      "name": "Stored Procedures",
      "description": "All data access stored procedures",
      "items": [...]
    },
    {
      "tier": 3,
      "name": "API Layer",
      "description": ".NET 8 controllers, services, DTOs",
      "items": [...]
    },
    {
      "tier": 4,
      "name": "Frontend Components",
      "description": "React 18 components matching Figma",
      "items": [...]
    },
    {
      "tier": 5,
      "name": "Integration & Config",
      "description": "Routing, auth, config, middleware",
      "items": [...]
    },
    {
      "tier": 6,
      "name": "Compliance & Polish",
      "description": "HIPAA/SOC2/PCI/GDPR patterns, error handling, logging",
      "items": [...]
    }
  ]
}
```

## Tier Guidelines
- Tier 1: Database schema (migrations, tables)
- Tier 2: Stored procedures (all data access)
- Tier 3: Backend API (.NET 8 controllers, services, repositories, DTOs, validators)
- Tier 4: Frontend (React components, pages, hooks, state - match Figma EXACTLY)
- Tier 5: Integration (routing, auth flows, middleware, DI registration, config files)
- Tier 6: Compliance & polish (audit logging, encryption, RBAC, error boundaries, accessibility)

## Rules
- EVERY file the project needs must have a blueprint item. Miss nothing.
- Items within a tier are ordered by dependency (build foundations first)
- Each item has concrete acceptance criteria (how to verify it's done)
- For React components, reference the exact Figma frame
- For stored procedures, reference the exact spec section
- For API endpoints, include HTTP method, route, request/response shape
- Keep descriptions to ONE sentence
- Acceptance criteria: 2-5 bullet points per item, testable assertions

## Patterns to enforce in the blueprint
- Backend: .NET 8 + Dapper + SQL Server stored procedures ONLY
- Frontend: React 18 functional components + hooks
- API: Contract-first, RESTful
- Database: Stored procs only, parameterized, audit columns
- Compliance: HIPAA, SOC 2, PCI, GDPR

## Also write
- {{GSD_DIR}}\blueprint\health.json: { "total": N, "completed": 0, "health": 0, "current_tier": 1 }
- {{GSD_DIR}}\blueprint\figma-tokens.md: extracted design tokens (colors, fonts, spacing)

Be EXHAUSTIVE. Every missing item is a file that won't get generated.
'@

Set-Content -Path "$BlueprintDir\prompts\claude\blueprint.md" -Value $claudeBlueprint -Encoding UTF8
Write-Host "   [OK] prompts\claude\blueprint.md" -ForegroundColor DarkGreen

# -- PHASE 3: VERIFY (Claude Code - per iteration) --
$claudeVerify = @'
# Verify Phase - Claude Code
# Per-iteration: check what exists vs blueprint, score health

You are the VERIFIER. Quick, binary checks. Conserve tokens.

## Context
- Iteration: {{ITERATION}}
- Health: {{HEALTH}}%
- Blueprint: {{GSD_DIR}}\blueprint\blueprint.json
- Project: {{REPO_ROOT}}

## Do (be FAST and CONCISE)

### 1. Read blueprint.json

### 2. For each item with status "in_progress" or recently built:
Check the file at the specified path:
- Does the file EXIST? -> if no, status stays "not_started"
- Does it meet the acceptance criteria? -> check each criterion
  - ALL criteria met -> set status "completed"
  - SOME criteria met -> set status "partial", note which failed
  - NO criteria met -> set status "not_started"

### 3. Calculate health
```
completed = count of items with status "completed"
total = total items in blueprint
health = (completed / total) * 100
```

### 4. Determine next batch
Find the lowest tier with incomplete items. Select up to {{BATCH_SIZE}} items
from that tier (respecting depends_on - only items whose dependencies are completed).

### 5. Write outputs

Update: {{GSD_DIR}}\blueprint\blueprint.json (status fields only)

Write: {{GSD_DIR}}\blueprint\health.json
```json
{
  "total": N,
  "completed": N,
  "partial": N,
  "not_started": N,
  "health": NN.N,
  "current_tier": N,
  "current_tier_name": "...",
  "iteration": {{ITERATION}}
}
```

Append to: {{GSD_DIR}}\blueprint\health-history.jsonl
```json
{"iteration":N,"health":NN.N,"completed":N,"total":N,"tier":N,"timestamp":"..."}
```

Write: {{GSD_DIR}}\blueprint\next-batch.json
```json
{
  "iteration": {{ITERATION}},
  "tier": N,
  "tier_name": "...",
  "items": [
    {
      "id": N,
      "path": "...",
      "type": "...",
      "description": "...",
      "acceptance": ["..."],
      "pattern": "...",
      "spec_source": "...",
      "figma_frame": "..."
    }
  ]
}
```

If any items are "partial", write: {{GSD_DIR}}\blueprint\partial-fixes.md
with SPECIFIC instructions on what's missing per partial item.

## Token Budget
~2000 tokens max. NO prose. Only update JSON statuses and write next-batch.
If health >= 100, set health.json status to "converged" and stop.
'@

Set-Content -Path "$BlueprintDir\prompts\claude\verify.md" -Value $claudeVerify -Encoding UTF8
Write-Host "   [OK] prompts\claude\verify.md" -ForegroundColor DarkGreen

Write-Host ""

# ========================================================
# STEP 4: Codex prompt (build)
# ========================================================

Write-Host "[WRENCH] Creating Codex prompt (build)..." -ForegroundColor Yellow

$codexBuild = @'
# Build Phase - Codex
# Per-iteration: generate code for the next batch from blueprint
# You have UNLIMITED tokens. Generate COMPLETE, PRODUCTION-READY files.

## Context
- Iteration: {{ITERATION}}
- Health: {{HEALTH}}%
- Project: {{REPO_ROOT}}

## Read These Files
1. {{GSD_DIR}}\blueprint\next-batch.json - YOUR WORK ORDER (the items to build NOW)
2. {{GSD_DIR}}\blueprint\blueprint.json - full blueprint for context and dependencies
3. {{GSD_DIR}}\blueprint\figma-tokens.md - design tokens (if exists)
4. {{GSD_DIR}}\blueprint\partial-fixes.md - fixes needed for partial items (if exists)
5. docs\ - SDLC specification documents (read sections referenced in spec_source)
6. {{FIGMA_PATH}} - Figma designs (check frames referenced in figma_frame)
7. Existing source code - understand current project state

## For Each Item in next-batch.json

### Read its spec_source
Go to the spec document referenced. Read the FULL section. Understand every detail.

### Read its figma_frame (if UI component)
Look at the Figma file referenced. Match the design EXACTLY.

### Generate the File
Create the COMPLETE file at the path specified. Not a snippet - the full file.

### Follow Project Patterns STRICTLY

**SQL Migrations & Stored Procedures:**
- Parameterized queries ONLY (never string concatenation)
- Include IF EXISTS checks for idempotent migrations
- Audit columns: CreatedAt DATETIME2, CreatedBy NVARCHAR(100), ModifiedAt, ModifiedBy
- Proper indexing on foreign keys and lookup columns
- GRANT EXECUTE permissions in stored procedures
- TRY/CATCH with THROW in stored procedures

**.NET 8 Backend:**
- Dapper for ALL data access (never Entity Framework)
- Repository pattern: IUserRepository -> UserRepository calling stored procedures
- Service layer: IUserService -> UserService with business logic
- Controllers: thin, delegate to services, return proper HTTP status codes
- DTOs: separate request/response models, never expose entities
- FluentValidation for input validation
- Serilog structured logging
- Dependency injection registration in Program.cs

**React 18 Frontend:**
- Functional components with hooks ONLY
- Match Figma: exact colors, spacing, typography, responsive breakpoints
- Accessibility: ARIA labels, keyboard nav, focus management
- Error boundaries at route level
- Loading states / skeleton screens
- Use design tokens from figma-tokens.md

**Compliance Patterns:**
- HIPAA: [Authorize] on PHI endpoints, audit log PHI access, encrypt at rest
- SOC 2: Role-based [Authorize(Roles = "...")] on all endpoints
- PCI: never log card numbers, tokenization for payment data
- GDPR: consent tracking, data export endpoint, data deletion endpoint

### Meet ALL Acceptance Criteria
After generating each file, mentally verify it meets every acceptance criterion
listed in the blueprint item. If it doesn't, fix it before moving on.

### Handle Partial Items
If partial-fixes.md exists, address those specific issues FIRST before new items.
Partial items are items that were generated previously but didn't fully meet criteria.

## After Generating All Items

Append to {{GSD_DIR}}\blueprint\build-log.jsonl:
```json
{
  "iteration": {{ITERATION}},
  "items_built": [1, 2, 3],
  "items_fixed": [4],
  "files_created": ["src/path/file.cs"],
  "files_modified": ["src/path/existing.cs"],
  "timestamp": "..."
}
```

## Boundaries
- DO NOT modify {{GSD_DIR}}\blueprint\blueprint.json (that's the verifier's job)
- DO NOT modify {{GSD_DIR}}\blueprint\health.json
- DO NOT modify {{GSD_DIR}}\blueprint\next-batch.json
- WRITE source code files + build-log.jsonl ONLY
'@

Set-Content -Path "$BlueprintDir\prompts\codex\build.md" -Value $codexBuild -Encoding UTF8
Write-Host "   [OK] prompts\codex\build.md" -ForegroundColor DarkGreen

Write-Host ""

# ========================================================
# STEP 5: Main blueprint pipeline script
# ========================================================

Write-Host "[SYNC] Creating blueprint-pipeline.ps1..." -ForegroundColor Yellow

$pipelineScript = @'
<#
.SYNOPSIS
    Blueprint Pipeline - Spec + Figma -> Code generator
    3-phase pipeline: blueprint (once) -> build (codex) -> verify (claude) -> loop

.USAGE
    cd C:\path\to\repo
    gsd-blueprint                         # full pipeline
    gsd-blueprint -DryRun                 # preview
    gsd-blueprint -BlueprintOnly          # just generate the manifest
    gsd-blueprint -BuildOnly              # resume from existing blueprint
    gsd-blueprint -MaxIterations 10       # limit cycles
    gsd-blueprint -BatchSize 20           # items per build cycle
    gsd-blueprint -VerifyOnly             # just re-score without building
#>

param(
    [int]$MaxIterations = 30,
    [int]$StallThreshold = 3,
    [int]$BatchSize = 15,
    [switch]$DryRun,
    [switch]$BlueprintOnly,
    [switch]$BuildOnly,
    [switch]$VerifyOnly
)

$ErrorActionPreference = "Continue"
$RepoRoot = (Get-Location).Path
$UserHome = $env:USERPROFILE
$GlobalDir = Join-Path $UserHome ".gsd-global"
$BpGlobalDir = Join-Path $GlobalDir "blueprint"
$GsdDir = Join-Path $RepoRoot ".gsd"
$BpDir = Join-Path $GsdDir "blueprint"

# -- Validate global install --
if (-not (Test-Path $BpGlobalDir)) {
    Write-Host "[XX] Blueprint Pipeline not installed. Run install-gsd-blueprint.ps1 first." -ForegroundColor Red
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

# -- Detect docs --
$docsPath = Join-Path $RepoRoot "docs"
$hasDocs = Test-Path $docsPath
$hasFigma = $FigmaVersion -ne "none"

# -- Initialize per-project blueprint state --
$projectDirs = @(
    $GsdDir, $BpDir, "$GsdDir\logs"
)
foreach ($dir in $projectDirs) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

$BlueprintFile = Join-Path $BpDir "blueprint.json"
$HealthFile = Join-Path $BpDir "health.json"
$HealthLog = Join-Path $BpDir "health-history.jsonl"
$NextBatchFile = Join-Path $BpDir "next-batch.json"
$BuildLog = Join-Path $BpDir "build-log.jsonl"

# -- Init health if missing --
if (-not (Test-Path $HealthFile)) {
    @{
        total = 0; completed = 0; partial = 0; not_started = 0
        health = 0; current_tier = 0; current_tier_name = "none"
        iteration = 0; status = "not_started"
    } | ConvertTo-Json | Set-Content $HealthFile -Encoding UTF8
}

# -- Helpers --
function Get-Health {
    try {
        $json = Get-Content $HealthFile -Raw | ConvertFrom-Json
        return [double]$json.health
    } catch { return 0 }
}

function Get-HealthStatus {
    try {
        return (Get-Content $HealthFile -Raw | ConvertFrom-Json).status
    } catch { return "not_started" }
}

function Has-Blueprint {
    if (-not (Test-Path $BlueprintFile)) { return $false }
    try {
        $bp = Get-Content $BlueprintFile -Raw | ConvertFrom-Json
        return ($bp.tiers.Count -gt 0)
    } catch { return $false }
}

function Resolve-Prompt($templatePath, $iter, $health) {
    $text = Get-Content $templatePath -Raw
    return $text.Replace("{{ITERATION}}", "$iter").Replace("{{HEALTH}}", "$health").Replace("{{GSD_DIR}}", $GsdDir).Replace("{{REPO_ROOT}}", $RepoRoot).Replace("{{FIGMA_PATH}}", $FigmaPath).Replace("{{FIGMA_VERSION}}", $FigmaVersion).Replace("{{BATCH_SIZE}}", "$BatchSize")
}

# -- Start --
$Iteration = 0
$Health = Get-Health
$StallCount = 0
$TargetHealth = 100

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Blue
Write-Host "  * Blueprint Pipeline" -ForegroundColor Blue
Write-Host "=========================================================" -ForegroundColor Blue
Write-Host "  Repo:       $RepoRoot" -ForegroundColor White
Write-Host "  Figma:      $FigmaVersion ($FigmaPath)" -ForegroundColor White
Write-Host "  Docs:       $(if ($hasDocs) { 'docs\' } else { 'none' })" -ForegroundColor White
Write-Host "  Health:     ${Health}% -> target ${TargetHealth}%" -ForegroundColor White
Write-Host "  Batch size: $BatchSize items per cycle" -ForegroundColor White
Write-Host "  Max iters:  $MaxIterations" -ForegroundColor White
Write-Host "  Blueprint:  $(if (Has-Blueprint) { 'EXISTS' } else { 'needs generation' })" -ForegroundColor $(if (Has-Blueprint) { 'Green' } else { 'Yellow' })
if ($DryRun) { Write-Host "  MODE:       DRY RUN" -ForegroundColor Yellow }
if ($BlueprintOnly) { Write-Host "  MODE:       BLUEPRINT ONLY" -ForegroundColor Yellow }
if ($BuildOnly) { Write-Host "  MODE:       BUILD ONLY (skip blueprint)" -ForegroundColor Yellow }
if ($VerifyOnly) { Write-Host "  MODE:       VERIFY ONLY" -ForegroundColor Yellow }
Write-Host "=========================================================" -ForegroundColor Blue
Write-Host ""

# ========================================================
# PHASE 1: BLUEPRINT (Claude Code - one time)
# ========================================================

$needsBlueprint = (-not (Has-Blueprint)) -and (-not $BuildOnly) -and (-not $VerifyOnly)

if ($needsBlueprint) {
    Write-Host "* PHASE 1: BLUEPRINT (Claude Code)" -ForegroundColor Blue
    Write-Host "  Reading all specs + Figma -> generating complete build manifest..." -ForegroundColor DarkGray
    Write-Host ""

    $prompt = Resolve-Prompt "$BpGlobalDir\prompts\claude\blueprint.md" 0 0

    if (-not $DryRun) {
        $startTime = Get-Date
        claude -p $prompt --allowedTools "Read,Write,Edit,Bash,mcp__*" 2>&1 |
            Tee-Object "$GsdDir\logs\blueprint-phase1-generate.log"
        $elapsed = (Get-Date) - $startTime

        if (Has-Blueprint) {
            $bp = Get-Content $BlueprintFile -Raw | ConvertFrom-Json
            $totalItems = 0
            $bp.tiers | ForEach-Object { $totalItems += $_.items.Count }
            Write-Host ""
            Write-Host "  [OK] Blueprint generated: $totalItems items across $($bp.tiers.Count) tiers" -ForegroundColor Green
            Write-Host "  [TIME]  Took: $([math]::Round($elapsed.TotalMinutes, 1)) minutes" -ForegroundColor DarkGray

            # Display tier summary
            Write-Host ""
            Write-Host "  Tier Breakdown:" -ForegroundColor Yellow
            foreach ($tier in $bp.tiers) {
                $count = $tier.items.Count
                Write-Host "    Tier $($tier.tier): $($tier.name) ($count items)" -ForegroundColor White
            }
            Write-Host ""
        } else {
            Write-Host "  [XX] Blueprint generation failed. Check logs." -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host "  [DRY RUN] claude -> blueprint generation" -ForegroundColor DarkYellow
    }

    if ($BlueprintOnly) {
        Write-Host "  BlueprintOnly mode - stopping here." -ForegroundColor Yellow
        Write-Host "  [DOC] Blueprint: $BlueprintFile" -ForegroundColor DarkGray
        Write-Host ""
        exit 0
    }
} elseif ($BlueprintOnly -and (Has-Blueprint)) {
    Write-Host "  [>>]  Blueprint already exists. Use -BuildOnly to resume, or delete blueprint.json to regenerate." -ForegroundColor Yellow
    exit 0
} elseif ($BuildOnly -and (-not (Has-Blueprint))) {
    Write-Host "  [XX] No blueprint.json found. Run without -BuildOnly first." -ForegroundColor Red
    exit 1
} else {
    $bp = Get-Content $BlueprintFile -Raw | ConvertFrom-Json
    $totalItems = 0
    $bp.tiers | ForEach-Object { $totalItems += $_.items.Count }
    Write-Host "  [>>]  Blueprint exists ($totalItems items). Starting build/verify loop." -ForegroundColor DarkGray
    Write-Host ""
}

# ========================================================
# VERIFY-ONLY MODE
# ========================================================

if ($VerifyOnly) {
    Write-Host "* VERIFY ONLY: Scoring health..." -ForegroundColor Blue

    $prompt = Resolve-Prompt "$BpGlobalDir\prompts\claude\verify.md" 0 $Health

    if (-not $DryRun) {
        claude -p $prompt --allowedTools "Read,Write,Edit,Bash,mcp__*" 2>&1 |
            Tee-Object "$GsdDir\logs\blueprint-verify-only.log"
        $Health = Get-Health
        Write-Host "  [CHART] Health: ${Health}%" -ForegroundColor Yellow
    } else {
        Write-Host "  [DRY RUN] claude -> verify" -ForegroundColor DarkYellow
    }
    exit 0
}

# ========================================================
# MAIN LOOP: BUILD (Codex) -> VERIFY (Claude Code)
# ========================================================

$Health = Get-Health

while ($Health -lt $TargetHealth -and $Iteration -lt $MaxIterations -and $StallCount -lt $StallThreshold) {
    $Iteration++
    $PrevHealth = $Health

    Write-Host "=== Iteration $Iteration / $MaxIterations | Health: ${Health}% | Target: ${TargetHealth}% ===" -ForegroundColor White

    # ==================================
    # STEP A: VERIFY (Claude Code)
    # Score current state + pick next batch
    # ==================================
    Write-Host "  [SEARCH] CLAUDE CODE -> verify + select next batch" -ForegroundColor Cyan

    $prompt = Resolve-Prompt "$BpGlobalDir\prompts\claude\verify.md" $Iteration $Health

    if (-not $DryRun) {
        claude -p $prompt --allowedTools "Read,Write,Edit,Bash,mcp__*" 2>&1 |
            Tee-Object "$GsdDir\logs\blueprint-iter${Iteration}-1-verify.log"
    } else {
        Write-Host "    [DRY RUN] claude -> verify" -ForegroundColor DarkYellow
    }

    $Health = Get-Health
    Write-Host "  [CHART] Health: ${Health}%" -ForegroundColor Yellow

    # Check convergence
    if ($Health -ge $TargetHealth) {
        Write-Host "  [OK] CONVERGED!" -ForegroundColor Green
        break
    }

    # Check if next-batch exists and has items
    if (-not $DryRun -and (Test-Path $NextBatchFile)) {
        try {
            $batch = Get-Content $NextBatchFile -Raw | ConvertFrom-Json
            $batchCount = $batch.items.Count
            Write-Host "  [CLIP] Next batch: $batchCount items from Tier $($batch.tier) ($($batch.tier_name))" -ForegroundColor DarkGray
        } catch {
            Write-Host "  [!!]  Could not parse next-batch.json" -ForegroundColor DarkYellow
        }
    }

    # ==================================
    # STEP B: BUILD (Codex)
    # Generate code for the batch
    # ==================================
    Write-Host "  [WRENCH] CODEX -> build next batch" -ForegroundColor Magenta

    $prompt = Resolve-Prompt "$BpGlobalDir\prompts\codex\build.md" $Iteration $Health

    if (-not $DryRun) {
        $buildStart = Get-Date
        codex --approval-mode full-auto --quiet $prompt 2>&1 |
            Tee-Object "$GsdDir\logs\blueprint-iter${Iteration}-2-build.log"
        $buildElapsed = (Get-Date) - $buildStart

        Write-Host "  [TIME]  Build took: $([math]::Round($buildElapsed.TotalMinutes, 1)) min" -ForegroundColor DarkGray

        # Git commit
        git add -A
        git commit -m "blueprint: iter $Iteration build (health: ${Health}%)" --no-verify 2>$null
    } else {
        Write-Host "    [DRY RUN] codex -> build" -ForegroundColor DarkYellow
    }

    # -- Stall detection --
    # We need to re-verify to get new health, but we can check if batch was empty
    $NewHealth = Get-Health
    if ($NewHealth -le $PrevHealth -and $Iteration -gt 1) {
        $StallCount++
        Write-Host "  [!!]  No progress: ${PrevHealth}% -> ${NewHealth}% | Stall $StallCount/$StallThreshold" -ForegroundColor DarkYellow

        if ($StallCount -ge $StallThreshold) {
            Write-Host "  [STOP] Stalled. Running diagnosis..." -ForegroundColor Red
            if (-not $DryRun) {
                $stallPrompt = @"
The blueprint pipeline stalled for $StallCount iterations at ${NewHealth}% health.
Read:
- $BpDir\blueprint.json (check items with status partial or not_started)
- $BpDir\health-history.jsonl
- $BpDir\build-log.jsonl
Diagnose why items aren't being completed. Common causes:
- Codex generating files that don't meet acceptance criteria
- Dependencies not actually satisfied
- File paths don't match blueprint
- Spec ambiguity in acceptance criteria
Write diagnosis to $BpDir\stall-diagnosis.md with specific fixes.
"@
                claude -p $stallPrompt --allowedTools "Read,Write,Bash" 2>&1 |
                    Tee-Object "$GsdDir\logs\blueprint-stall-diagnosis-$Iteration.log"
            }
            break
        }
    } else {
        $StallCount = 0
    }

    $Health = $NewHealth
    Write-Host "  [SYNC] Iteration $Iteration complete. Health: ${Health}%" -ForegroundColor Cyan
    Write-Host ""
    Start-Sleep -Seconds 2
}

# ========================================================
# FINAL REPORT
# ========================================================

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Blue
$FinalHealth = Get-Health

if ($FinalHealth -ge $TargetHealth) {
    Write-Host "  [PARTY] BLUEPRINT COMPLETE - ${FinalHealth}% in $Iteration iterations" -ForegroundColor Green
    if (-not $DryRun) {
        git add -A
        git commit -m "blueprint: COMPLETE - 100% health in $Iteration iterations" --no-verify 2>$null
        git tag "blueprint-complete-$(Get-Date -Format 'yyyyMMdd-HHmmss')" 2>$null
    }
} elseif ($StallCount -ge $StallThreshold) {
    Write-Host "  [STOP] STALLED at ${FinalHealth}%" -ForegroundColor Red
    Write-Host "     See: $BpDir\stall-diagnosis.md" -ForegroundColor Red
} else {
    Write-Host "  [!!]  MAX ITERATIONS at ${FinalHealth}%" -ForegroundColor Yellow
    Write-Host "     Run again to continue: gsd-blueprint -BuildOnly" -ForegroundColor Yellow
}

# Show stats
if (Test-Path $HealthLog) {
    $entries = Get-Content $HealthLog | ForEach-Object { $_ | ConvertFrom-Json }
    if ($entries.Count -gt 1) {
        Write-Host ""
        Write-Host "  Health Progression:" -ForegroundColor DarkGray
        foreach ($e in $entries) {
            $bar = "#" * [math]::Floor($e.health / 5)
            $pad = "." * (20 - [math]::Floor($e.health / 5))
            Write-Host "    Iter $($e.iteration): [$bar$pad] $($e.health)% (Tier $($e.tier))" -ForegroundColor DarkGray
        }
    }
}

Write-Host ""
Write-Host "  Blueprint:  $BlueprintFile" -ForegroundColor DarkGray
Write-Host "  Health:     $HealthFile" -ForegroundColor DarkGray
Write-Host "  Logs:       $GsdDir\logs\" -ForegroundColor DarkGray
Write-Host "=========================================================" -ForegroundColor Blue
Write-Host ""
Write-Host "  To switch to maintenance mode: gsd-converge" -ForegroundColor DarkGray
Write-Host ""
'@

Set-Content -Path "$BlueprintDir\scripts\blueprint-pipeline.ps1" -Value $pipelineScript -Encoding UTF8
Write-Host "   [OK] scripts\blueprint-pipeline.ps1" -ForegroundColor DarkGreen

Write-Host ""

# ========================================================
# STEP 6: Global command + profile function
# ========================================================

Write-Host "Setting up global 'gsd-blueprint' command..." -ForegroundColor Yellow

# CMD wrapper
$binDir = Join-Path $GsdGlobalDir "bin"
$wrapperCmd = @"
@echo off
powershell -ExecutionPolicy Bypass -File "%USERPROFILE%\.gsd-global\blueprint\scripts\blueprint-pipeline.ps1" %*
"@

Set-Content -Path "$binDir\gsd-blueprint.cmd" -Value $wrapperCmd -Encoding ASCII
Write-Host "   [OK] bin\gsd-blueprint.cmd" -ForegroundColor DarkGreen

# CMD wrapper for gsd-status (calls the profile function via PowerShell)
$statusCmd = @"
@echo off
powershell -ExecutionPolicy Bypass -NoProfile -Command "& { . '%USERPROFILE%\.gsd-global\scripts\gsd-profile-functions.ps1'; gsd-status }"
"@

Set-Content -Path "$binDir\gsd-status.cmd" -Value $statusCmd -Encoding ASCII
Write-Host "   [OK] bin\gsd-status.cmd" -ForegroundColor DarkGreen

# PowerShell profile function
$profileFunctions = @'
function gsd-blueprint {
    param(
        [switch]$DryRun, [switch]$BlueprintOnly, [switch]$BuildOnly, [switch]$VerifyOnly,
        [int]$MaxIterations = 30, [int]$StallThreshold = 3, [int]$BatchSize = 15
    )
    $params = @{ MaxIterations=$MaxIterations; StallThreshold=$StallThreshold; BatchSize=$BatchSize }
    if ($DryRun) { $params.DryRun = $true }
    if ($BlueprintOnly) { $params.BlueprintOnly = $true }
    if ($BuildOnly) { $params.BuildOnly = $true }
    if ($VerifyOnly) { $params.VerifyOnly = $true }
    & "$env:USERPROFILE\.gsd-global\blueprint\scripts\blueprint-pipeline.ps1" @params
}

function gsd-status {
    Write-Host ""
    $repoRoot = (Get-Location).Path
    $bpHealth = Join-Path $repoRoot ".gsd\blueprint\health.json"
    $gsdHealth = Join-Path $repoRoot ".gsd\health\health-current.json"

    Write-Host "  [CHART] GSD Status: $repoRoot" -ForegroundColor Cyan
    Write-Host "  -------------------------------------" -ForegroundColor DarkGray

    if (Test-Path $bpHealth) {
        $h = Get-Content $bpHealth -Raw | ConvertFrom-Json
        $bar = "#" * [math]::Floor($h.health / 5)
        $pad = "." * (20 - [math]::Floor($h.health / 5))
        Write-Host "  Blueprint:  [$bar$pad] $($h.health)% ($($h.completed)/$($h.total) items)" -ForegroundColor Blue
        Write-Host "              Tier $($h.current_tier): $($h.current_tier_name)" -ForegroundColor DarkGray
    } else {
        Write-Host "  Blueprint:  not initialized" -ForegroundColor DarkGray
    }

    if (Test-Path $gsdHealth) {
        $h = Get-Content $gsdHealth -Raw | ConvertFrom-Json
        $bar = "#" * [math]::Floor($h.health_score / 5)
        $pad = "." * (20 - [math]::Floor($h.health_score / 5))
        Write-Host "  GSD Health: [$bar$pad] $($h.health_score)% ($($h.satisfied)/$($h.total_requirements) reqs)" -ForegroundColor Green
    } else {
        Write-Host "  GSD Health: not initialized" -ForegroundColor DarkGray
    }

    # Detect Figma version
    $figmaBase = Join-Path $repoRoot "design\figma"
    if (Test-Path $figmaBase) {
        $latest = Get-ChildItem -Path $figmaBase -Directory |
            Where-Object { $_.Name -match '^v(\d+)$' } |
            Sort-Object { [int]($_.Name -replace '^v', '') } -Descending |
            Select-Object -First 1
        if ($latest) {
            Write-Host "  Figma:      $($latest.Name)" -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    Write-Host "  Commands:" -ForegroundColor Yellow
    Write-Host "    gsd-blueprint              Greenfield generation" -ForegroundColor White
    Write-Host "    gsd-converge               Maintenance loop" -ForegroundColor White
    Write-Host "    gsd-status                 This screen" -ForegroundColor White
    Write-Host ""
}
'@

# Append to existing profile functions file or create new one
$profileFile = Join-Path $GsdGlobalDir "scripts\gsd-profile-functions.ps1"
if (Test-Path $profileFile) {
    $existing = Get-Content $profileFile -Raw
    if ($existing -match "gsd-blueprint") {
        # Replace existing blueprint functions section
        $existing = $existing -replace '(?s)# Blueprint Pipeline Functions.*?(?=\n# [A-Z]|\z)', ''
        Set-Content -Path $profileFile -Value $existing.TrimEnd() -Encoding UTF8
    }
    Add-Content -Path $profileFile -Value "`n$profileFunctions" -Encoding UTF8
    Write-Host "   [OK] Updated blueprint functions in gsd-profile-functions.ps1" -ForegroundColor DarkGreen
} else {
    Set-Content -Path $profileFile -Value $profileFunctions -Encoding UTF8
    Write-Host "   [OK] Created gsd-profile-functions.ps1" -ForegroundColor DarkGreen
}

# Ensure profile sources the functions file
$psProfilePath = $PROFILE.CurrentUserAllHosts
# Fallback when $PROFILE is empty (non-interactive / invoked from bash)
if ([string]::IsNullOrWhiteSpace($psProfilePath)) {
    $psProfilePath = Join-Path $env:USERPROFILE "Documents\PowerShell\profile.ps1"
}
$psProfileDir = Split-Path $psProfilePath -Parent
if (-not (Test-Path $psProfileDir)) {
    New-Item -ItemType Directory -Path $psProfileDir -Force | Out-Null
}

$profileLine = ". `"$GsdGlobalDir\scripts\gsd-profile-functions.ps1`""
if (Test-Path $psProfilePath) {
    $existingProfile = Get-Content $psProfilePath -Raw
    if ($existingProfile -notmatch "gsd-profile-functions") {
        Add-Content -Path $psProfilePath -Value "`n# GSD Engine`n$profileLine" -Encoding UTF8
        Write-Host "   [OK] Added to PowerShell profile" -ForegroundColor DarkGreen
    }
} else {
    Set-Content -Path $psProfilePath -Value "# GSD Engine`n$profileLine" -Encoding UTF8
    Write-Host "   [OK] Created PowerShell profile" -ForegroundColor DarkGreen
}

# Ensure bin in PATH
$currentPath = [Environment]::GetEnvironmentVariable("PATH", "User")
if ($currentPath -notlike "*$binDir*") {
    [Environment]::SetEnvironmentVariable("PATH", "$currentPath;$binDir", "User")
    Write-Host "   [OK] Added bin\ to PATH" -ForegroundColor DarkGreen
}

Write-Host ""

# ========================================================
# STEP 7: Update Claude + Codex global configs
# ========================================================

Write-Host "[MEMO] Updating agent global configs..." -ForegroundColor Yellow

# Append blueprint role to CLAUDE.md
$claudeFile = Join-Path $ClaudeDir "CLAUDE.md"
$blueprintClaudeSection = @"

## Blueprint Pipeline Role

When running the blueprint pipeline (gsd-blueprint), you handle 2 phases:

### Phase 1: BLUEPRINT (one-time)
Read ALL specs + Figma -> produce blueprint.json with every file the project needs.
Output: ~5K tokens. Be exhaustive - every missing item won't get built.

### Phase 3: VERIFY (per iteration)
Binary check: does each file exist and meet acceptance criteria?
Output: ~2K tokens. NO prose. Update statuses, write next-batch.json.

### Token Discipline (Blueprint mode)
- Blueprint phase: ~5K tokens (one time)
- Verify phase: ~2K tokens per iteration
- Total per iteration: ~2K (much less than GSD mode)
"@

if (Test-Path $claudeFile) {
    $existing = Get-Content $claudeFile -Raw
    if ($existing -match "Blueprint Pipeline Role") {
        # Replace existing section
        $existing = $existing -replace '(?s)## Blueprint Pipeline Role.*?(?=\n## |\z)', ''
        Set-Content -Path $claudeFile -Value $existing.TrimEnd() -Encoding UTF8
    }
    Add-Content -Path $claudeFile -Value $blueprintClaudeSection -Encoding UTF8
    Write-Host "   [OK] Updated .claude\CLAUDE.md with blueprint role" -ForegroundColor DarkGreen
} else {
    Set-Content -Path $claudeFile -Value "# Claude Code Global Config`n$blueprintClaudeSection" -Encoding UTF8
    Write-Host "   [OK] Created .claude\CLAUDE.md" -ForegroundColor DarkGreen
}

# Append blueprint role to Codex instructions
$codexFile = Join-Path $CodexDir "instructions.md"
$blueprintCodexSection = @"

## Blueprint Pipeline Role

When running the blueprint pipeline (gsd-blueprint), you handle 1 phase:

### Phase 2: BUILD (per iteration)
Read next-batch.json -> generate COMPLETE production-ready files for each item.
You have UNLIMITED tokens. Generate full files, not snippets.
Follow all project patterns strictly (.NET 8 + Dapper + stored procs + React 18).
Meet EVERY acceptance criterion in the blueprint item.
DO NOT modify any files in .gsd\blueprint\ - only write source code.
"@

if (Test-Path $codexFile) {
    $existing = Get-Content $codexFile -Raw
    if ($existing -match "Blueprint Pipeline Role") {
        $existing = $existing -replace '(?s)## Blueprint Pipeline Role.*?(?=\n## |\z)', ''
        Set-Content -Path $codexFile -Value $existing.TrimEnd() -Encoding UTF8
    }
    Add-Content -Path $codexFile -Value $blueprintCodexSection -Encoding UTF8
    Write-Host "   [OK] Updated .codex\instructions.md with blueprint role" -ForegroundColor DarkGreen
} else {
    Set-Content -Path $codexFile -Value "# Codex Global Config`n$blueprintCodexSection" -Encoding UTF8
    Write-Host "   [OK] Created .codex\instructions.md" -ForegroundColor DarkGreen
}

Write-Host ""

# ========================================================
# STEP 8: VS Code tasks
# ========================================================

Write-Host "Creating VS Code tasks..." -ForegroundColor Yellow

$vscodeUserDir = Join-Path $env:APPDATA "Code\User"
if (-not (Test-Path $vscodeUserDir)) {
    $vscodeUserDir = Join-Path $env:APPDATA "Code - Insiders\User"
}

if (Test-Path $vscodeUserDir) {
    $bpTasksBackup = @{
        version = "2.0.0"
        tasks = @(
            @{
                label = "Blueprint: Full Pipeline"
                type = "shell"
                command = "powershell"
                args = @("-ExecutionPolicy", "Bypass", "-File",
                    "$BlueprintDir\scripts\blueprint-pipeline.ps1")
                presentation = @{ reveal="always"; panel="dedicated"; focus=$false; clear=$true }
                runOptions = @{ instanceLimit = 1 }
                problemMatcher = @()
                group = "build"
            },
            @{
                label = "Blueprint: Dry Run"
                type = "shell"
                command = "powershell"
                args = @("-ExecutionPolicy", "Bypass", "-File",
                    "$BlueprintDir\scripts\blueprint-pipeline.ps1", "-DryRun")
                presentation = @{ reveal="always"; panel="dedicated"; clear=$true }
                problemMatcher = @()
            },
            @{
                label = "Blueprint: Generate Only"
                type = "shell"
                command = "powershell"
                args = @("-ExecutionPolicy", "Bypass", "-File",
                    "$BlueprintDir\scripts\blueprint-pipeline.ps1", "-BlueprintOnly")
                presentation = @{ reveal="always"; panel="dedicated"; clear=$true }
                problemMatcher = @()
            },
            @{
                label = "Blueprint: Resume Build"
                type = "shell"
                command = "powershell"
                args = @("-ExecutionPolicy", "Bypass", "-File",
                    "$BlueprintDir\scripts\blueprint-pipeline.ps1", "-BuildOnly")
                presentation = @{ reveal="always"; panel="dedicated"; clear=$true }
                runOptions = @{ instanceLimit = 1 }
                problemMatcher = @()
            },
            @{
                label = "Blueprint: Verify Only"
                type = "shell"
                command = "powershell"
                args = @("-ExecutionPolicy", "Bypass", "-File",
                    "$BlueprintDir\scripts\blueprint-pipeline.ps1", "-VerifyOnly")
                presentation = @{ reveal="always"; panel="shared" }
                problemMatcher = @()
            },
            @{
                label = "GSD: Status Check"
                type = "shell"
                command = "powershell"
                args = @("-ExecutionPolicy", "Bypass", "-Command", "gsd-status")
                presentation = @{ reveal="always"; panel="shared" }
                problemMatcher = @()
            }
        )
    }

    $backupPath = Join-Path $vscodeUserDir "tasks.blueprint-backup.json"
    $bpTasksBackup | ConvertTo-Json -Depth 5 | Set-Content $backupPath -Encoding UTF8
    Write-Host "   [OK] VS Code tasks saved to tasks.blueprint-backup.json" -ForegroundColor DarkGreen
    Write-Host "      Merge into your tasks.json manually" -ForegroundColor DarkGray
} else {
    Write-Host "   [!!]  VS Code user dir not found" -ForegroundColor DarkYellow
}

Write-Host ""

# ========================================================
# DONE
# ========================================================

Write-Host "=========================================================" -ForegroundColor Green
Write-Host "  [OK] Blueprint Pipeline - Installed!" -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  YOU NOW HAVE TWO CAPABILITIES:" -ForegroundColor Yellow
Write-Host ""
Write-Host "  +---------------------------------------------------------+" -ForegroundColor DarkGray
Write-Host "  |  gsd-blueprint    Greenfield: Spec+Figma -> Code        |" -ForegroundColor Blue
Write-Host "  |                   3 phases, ~2K Claude tokens/iter     |" -ForegroundColor DarkGray
Write-Host "  |                   Best for: new projects, full gen     |" -ForegroundColor DarkGray
Write-Host "  |                                                        |" -ForegroundColor DarkGray
Write-Host "  |  gsd-converge     Maintenance: Review -> Fix -> Verify   |" -ForegroundColor Green
Write-Host "  |                   5 phases, ~11K Claude tokens/iter    |" -ForegroundColor DarkGray
Write-Host "  |                   Best for: existing code, iteration   |" -ForegroundColor DarkGray
Write-Host "  |                                                        |" -ForegroundColor DarkGray
Write-Host "  |  gsd-status       Check health of current project      |" -ForegroundColor Cyan
Write-Host "  +---------------------------------------------------------+" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  RECOMMENDED WORKFLOW:" -ForegroundColor Yellow
Write-Host "    1. gsd-blueprint                # generate from spec + Figma" -ForegroundColor White
Write-Host "    2. gsd-blueprint -BuildOnly     # resume if interrupted" -ForegroundColor White
Write-Host "    3. gsd-converge                 # switch to maintenance mode" -ForegroundColor White
Write-Host "    4. gsd-status                   # check progress anytime" -ForegroundColor White
Write-Host ""
Write-Host "  VS CODE:" -ForegroundColor Yellow
Write-Host "    Ctrl+Shift+P -> 'Run Task' -> 'Blueprint: Full Pipeline'" -ForegroundColor Cyan
Write-Host ""
Write-Host "  [!!]  RESTART YOUR TERMINAL for commands to work" -ForegroundColor Yellow
Write-Host ""
