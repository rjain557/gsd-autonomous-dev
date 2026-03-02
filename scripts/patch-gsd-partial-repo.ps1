<#
.SYNOPSIS
    GSD Partial Repo Patch
    Upgrades both gsd-blueprint and gsd-converge with robust partial-repo assessment.
    Run AFTER installing both engines.

.DESCRIPTION
    This patch:
    1. Adds a dedicated codebase assessment prompt for Claude Code
    2. Updates the blueprint prompt to do deep existing-code scanning
    3. Updates the verify prompt to handle partial-repo edge cases
    4. Adds a standalone gsd-assess command for pre-flight analysis
    5. Updates Codex prompts to respect existing code patterns

.USAGE
    powershell -ExecutionPolicy Bypass -File patch-gsd-partial-repo.ps1
#>

param(
    [string]$UserHome = $env:USERPROFILE
)

$ErrorActionPreference = "Stop"
$GsdGlobalDir = Join-Path $UserHome ".gsd-global"
$BlueprintDir = Join-Path $GsdGlobalDir "blueprint"

if (-not (Test-Path $GsdGlobalDir)) {
    Write-Host "[XX] GSD Global Engine not installed. Run the installers first." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  GSD Partial Repo Patch" -ForegroundColor Cyan
Write-Host "  Adding robust existing-codebase assessment" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

# Ensure directories exist
$promptDirs = @(
    "$GsdGlobalDir\prompts",
    "$GsdGlobalDir\prompts\claude",
    "$BlueprintDir\prompts\claude",
    "$BlueprintDir\prompts\codex",
    "$BlueprintDir\scripts"
)
foreach ($d in $promptDirs) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ========================================================
# STEP 1: Standalone Assessment Prompt (shared by both)
# ========================================================

Write-Host "[SEARCH] Creating codebase assessment prompt..." -ForegroundColor Yellow

$assessPrompt = @'
# Codebase Assessment - Claude Code
# Run this BEFORE blueprint or convergence on a partially-built repo.
# Produces a complete inventory of what exists, what's partial, and what's missing.

You are the ASSESSOR. Your job: produce a thorough inventory of the existing
codebase so that the generation phases know exactly what to skip, what to fix,
and what to build from scratch.

## Context
- Project: {{REPO_ROOT}}
- Figma: {{FIGMA_PATH}} (version {{FIGMA_VERSION}})
- SDLC docs: docs\ (Phase A through Phase E)
- Output: {{GSD_DIR}}\assessment\

## STEP 1: Discovery Scan

Scan the full repository. For EVERY file in the project (excluding node_modules,
bin, obj, .git, packages, dist, build), catalog:

```
{{GSD_DIR}}\assessment\file-inventory.json
{
  "scan_timestamp": "...",
  "total_files": N,
  "by_type": {
    ".cs": { "count": N, "paths": ["..."] },
    ".sql": { "count": N, "paths": ["..."] },
    ".tsx": { "count": N, "paths": ["..."] },
    ".ts": { "count": N, "paths": ["..."] },
    ".json": { "count": N, "paths": ["..."] },
    ".css": { "count": N, "paths": ["..."] },
    ".md": { "count": N, "paths": ["..."] }
  },
  "folder_structure": "... tree output ..."
}
```

## STEP 2: Pattern Detection

Read a representative sample of existing files (at least 3-5 of each type) and detect:

```
{{GSD_DIR}}\assessment\detected-patterns.json
{
  "backend": {
    "framework": ".NET 8 | .NET 7 | .NET 6 | other",
    "orm": "Dapper | Entity Framework | ADO.NET | other",
    "data_access": "stored procedures | inline SQL | ORM queries | mixed",
    "architecture": "clean architecture | MVC | minimal API | other",
    "di_pattern": "constructor injection | service locator | none",
    "logging": "Serilog | NLog | ILogger | Console | none",
    "validation": "FluentValidation | DataAnnotations | manual | none",
    "example_files": ["path/to/representative.cs"]
  },
  "frontend": {
    "framework": "React 18 | React 17 | Angular | Vue | other",
    "component_style": "functional + hooks | class components | mixed",
    "state_management": "Redux | Context | Zustand | MobX | none",
    "styling": "CSS modules | Tailwind | styled-components | SCSS | inline",
    "routing": "React Router | Next.js | other | none",
    "example_files": ["path/to/representative.tsx"]
  },
  "database": {
    "engine": "SQL Server | PostgreSQL | MySQL | SQLite | other",
    "migrations": "EF migrations | SQL scripts | Flyway | none",
    "stored_procedures_exist": true/false,
    "stored_procedure_count": N,
    "inline_sql_detected": true/false,
    "example_files": ["path/to/representative.sql"]
  },
  "compliance": {
    "hipaa_patterns_detected": true/false,
    "audit_logging_exists": true/false,
    "rbac_implemented": true/false,
    "encryption_at_rest": true/false,
    "evidence": ["path/to/audit-logger.cs"]
  },
  "pattern_conflicts": [
    {
      "issue": "Mixed data access: 12 files use EF, 3 files use Dapper",
      "recommendation": "Standardize on Dapper + stored procedures per project standards",
      "affected_files": ["..."]
    }
  ]
}
```

## STEP 3: Spec Coverage Analysis

Read each specification document in docs\ and each Figma design. For every
requirement, check if existing code satisfies it:

```
{{GSD_DIR}}\assessment\coverage-analysis.json
{
  "spec_coverage": {
    "total_requirements_identified": N,
    "fully_implemented": N,
    "partially_implemented": N,
    "not_implemented": N,
    "coverage_percent": NN.N
  },
  "figma_coverage": {
    "total_components_identified": N,
    "fully_implemented": N,
    "partially_implemented": N,
    "not_implemented": N,
    "coverage_percent": NN.N
  },
  "requirements": [
    {
      "id": "REQ-001",
      "source": "spec",
      "spec_doc": "docs/Phase-B-API.md",
      "description": "User authentication endpoint",
      "status": "fully_implemented",
      "implemented_by": ["src/Controllers/AuthController.cs", "src/Services/AuthService.cs"],
      "quality_notes": "Working but uses inline SQL instead of stored procedure",
      "needs_refactor": true,
      "refactor_reason": "Must use stored procedure pattern per project standards"
    },
    {
      "id": "REQ-042",
      "source": "figma",
      "figma_frame": "Dashboard/CardGrid",
      "description": "Dashboard card grid layout",
      "status": "partially_implemented",
      "implemented_by": ["src/components/Dashboard/CardGrid.tsx"],
      "quality_notes": "Component exists but missing responsive breakpoints and hover states from Figma",
      "missing": ["responsive breakpoints", "hover elevation shadow", "loading skeleton"]
    }
  ]
}
```

## STEP 4: Refactor vs Build Decision Map

For each requirement, classify the work needed:

```
{{GSD_DIR}}\assessment\work-classification.json
{
  "summary": {
    "skip": N,
    "refactor": N,
    "extend": N,
    "build_new": N,
    "total": N
  },
  "items": [
    {
      "req_id": "REQ-001",
      "classification": "skip",
      "reason": "Fully implemented, meets all acceptance criteria and project patterns"
    },
    {
      "req_id": "REQ-002",
      "classification": "refactor",
      "reason": "Implemented but uses Entity Framework instead of Dapper + stored procs",
      "current_file": "src/Repositories/UserRepository.cs",
      "work_needed": "Rewrite data access layer to use Dapper calling stored procedures",
      "estimated_complexity": "medium"
    },
    {
      "req_id": "REQ-042",
      "classification": "extend",
      "reason": "Component exists but incomplete - missing responsive + hover states",
      "current_file": "src/components/Dashboard/CardGrid.tsx",
      "work_needed": "Add responsive breakpoints, hover elevation, loading skeleton",
      "estimated_complexity": "low"
    },
    {
      "req_id": "REQ-099",
      "classification": "build_new",
      "reason": "No implementation exists",
      "work_needed": "Create from scratch per spec",
      "estimated_complexity": "high"
    }
  ]
}
```

Classifications:
- **skip**: Fully done, correct patterns, meets acceptance criteria. Don't touch it.
- **refactor**: Code exists but uses wrong patterns (e.g. EF instead of Dapper, inline SQL instead of stored procs). Must be rewritten.
- **extend**: Code exists and is partially correct. Needs additions (missing features, states, validations).
- **build_new**: Nothing exists. Generate from scratch.

## STEP 5: Summary Report

```
{{GSD_DIR}}\assessment\assessment-summary.md

# Codebase Assessment Summary
- **Project**: <name>
- **Assessed**: <timestamp>
- **Figma**: <version>

## Coverage
- Spec requirements: NN% covered (N/N)
- Figma components: NN% covered (N/N)
- Overall: NN%

## Work Breakdown
- Skip (already done): N items
- Refactor (wrong patterns): N items
- Extend (partially done): N items
- Build new: N items

## Pattern Conflicts
<list any conflicts found>

## Estimated Effort
- Refactors: ~N files to rewrite
- Extensions: ~N files to modify
- New code: ~N files to create
- Total: ~N files affected

## Recommendations
- <specific recommendations based on what was found>
```

## Rules
- Scan EVERY file, not just a sample - the inventory must be complete
- Read actual file contents to determine patterns (don't guess from names)
- Be HONEST about quality - if code works but uses wrong patterns, flag it as refactor
- For Figma comparison, check actual component output vs design, not just file existence
- Pattern conflicts must list specific files so Codex knows what to fix
- This assessment feeds directly into blueprint.json or requirements-matrix.json
'@

Set-Content -Path "$GsdGlobalDir\prompts\claude\assess.md" -Value $assessPrompt -Encoding UTF8
Write-Host "   [OK] prompts\claude\assess.md" -ForegroundColor DarkGreen

Write-Host ""

# ========================================================
# STEP 2: Updated Blueprint prompt (partial-repo aware)
# ========================================================

Write-Host "[CLIP] Updating blueprint prompt for partial repos..." -ForegroundColor Yellow

$blueprintPartialSection = @'

## CRITICAL: Partial Repo Handling

This repo may ALREADY have code. You MUST assess what exists before generating
the blueprint. Do NOT assume a greenfield project.

### Pre-Blueprint Assessment

BEFORE writing blueprint.json, perform this assessment:

1. **Scan the full codebase** - list every source file that exists
2. **Read representative files** - understand the patterns already in use
3. **Detect pattern conflicts** - flag any code using wrong patterns
   (e.g. Entity Framework when the standard is Dapper + stored procs)
4. **Cross-reference with specs** - for each spec requirement, check if
   code already exists that satisfies it

### Blueprint Item Status Rules for Partial Repos

When writing each blueprint item, set the initial status based on what you find:

- **"completed"** - File exists, correct patterns, meets ALL acceptance criteria.
  Set `satisfied_by` to the existing file path. Codex will SKIP this item.

- **"partial"** - File exists but incomplete or wrong patterns. Set status to
  "partial" and add a `partial_notes` field explaining what's wrong/missing:
  ```json
  {
    "id": 42,
    "path": "src/components/Dashboard/CardGrid.tsx",
    "status": "partial",
    "partial_notes": "Component exists but missing responsive breakpoints and hover states from Figma v03. Also using class component - must convert to functional + hooks.",
    "existing_file": "src/components/Dashboard/CardGrid.tsx",
    "work_type": "extend"
  }
  ```

- **"refactor"** - File exists but uses fundamentally wrong patterns. Set
  status to "refactor" with details:
  ```json
  {
    "id": 15,
    "path": "src/Repositories/UserRepository.cs",
    "status": "refactor",
    "partial_notes": "Currently uses Entity Framework. Must rewrite to Dapper + stored procedures. Keep the same interface (IUserRepository) but change implementation.",
    "existing_file": "src/Repositories/UserRepository.cs",
    "work_type": "refactor",
    "preserve": ["IUserRepository interface", "method signatures", "DI registration"]
  }
  ```

- **"not_started"** - Nothing exists. Codex builds from scratch.

### The `preserve` Field

For refactor and extend items, include a `preserve` array listing things
Codex must NOT break or change:
- Interface contracts that other code depends on
- DI registrations
- Route paths that the frontend calls
- Database column names that stored procs reference
- CSS class names that other components use

### Work Type Priorities

In the tier structure, order items within each tier by work_type:
1. **refactor** items first (fix wrong patterns before building on them)
2. **extend** items second (complete partial implementations)
3. **not_started** items last (new code)

This ensures the foundation is solid before building on top of it.

### Assessment Output

Also write: {{GSD_DIR}}\blueprint\pre-assessment.json
```json
{
  "assessed_at": "...",
  "existing_files_scanned": N,
  "pattern_conflicts": [...],
  "coverage": {
    "spec_coverage_percent": NN.N,
    "figma_coverage_percent": NN.N
  },
  "work_breakdown": {
    "skip_completed": N,
    "refactor": N,
    "extend": N,
    "build_new": N
  },
  "initial_health": NN.N
}
```
'@

# Write as a supplementary file that the blueprint prompt references
Set-Content -Path "$BlueprintDir\prompts\claude\partial-repo-guide.md" -Value $blueprintPartialSection -Encoding UTF8
Write-Host "   [OK] prompts\claude\partial-repo-guide.md" -ForegroundColor DarkGreen

Write-Host ""

# ========================================================
# STEP 3: Updated Codex build prompt (partial-repo aware)
# ========================================================

Write-Host "[WRENCH] Creating Codex partial-repo build guide..." -ForegroundColor Yellow

$codexPartialGuide = @'
# Codex Build Guide: Partial Repos
# Read this alongside the main build prompt when the blueprint contains
# items with status "partial", "refactor", or "extend"

## Handling Different Work Types

### status: "not_started"
Standard generation. Create the file from scratch following project patterns.

### status: "extend"
The file ALREADY EXISTS. You must:
1. READ the existing file completely first
2. UNDERSTAND what it already does
3. ADD the missing functionality described in partial_notes
4. PRESERVE everything in the `preserve` array - do NOT break existing behavior
5. Keep the file's existing structure/organization where possible
6. If the existing code has tests, make sure they still pass

Example: A React component exists but is missing responsive breakpoints.
- Read the existing component
- Add the media queries / responsive logic
- Don't change the existing props, state, or data flow
- Match the Figma design for the new responsive states

### status: "refactor"
The file ALREADY EXISTS but uses WRONG PATTERNS. You must:
1. READ the existing file completely - understand its behavior
2. READ what the `preserve` array requires you to keep
3. REWRITE the implementation using correct patterns
4. The external contract (interface, props, route, etc.) stays THE SAME
5. Internal implementation changes to match project standards

Example: A repository using Entity Framework must switch to Dapper + stored procs.
- Read the EF implementation to understand every method
- Keep the IRepository interface identical
- Rewrite every method to call stored procedures via Dapper
- Create the stored procedures that the new code needs
- Keep the DI registration the same (just new class implementing same interface)

### status: "completed"
SKIP THIS ITEM. Do not touch the file. It already meets all criteria.

## Critical Rules for Partial Repos

1. **NEVER delete a file without creating its replacement first**
2. **NEVER break an interface contract** - other code depends on it
3. **Always read existing code before modifying** - understand dependencies
4. **If unsure about a dependency**, err on the side of preserving it
5. **For refactors**, create the stored procedure BEFORE rewriting the repository
   (the new code needs the stored proc to exist)
6. **Test awareness**: if the project has tests, your changes should not break them

## Import / Dependency Awareness

Before modifying any file, check:
- What imports THIS file? (search for the filename in other files)
- What does this file import? (check its import statements)
- Is this file registered in DI? (check Program.cs / Startup.cs)
- Is this file in a route? (check routing config)

If you change a file's exports, you must update all files that import from it.
'@

Set-Content -Path "$BlueprintDir\prompts\codex\partial-repo-guide.md" -Value $codexPartialGuide -Encoding UTF8
Write-Host "   [OK] prompts\codex\partial-repo-guide.md" -ForegroundColor DarkGreen

Write-Host ""

# ========================================================
# STEP 4: Assessment script (standalone gsd-assess)
# ========================================================

Write-Host "[CHART] Creating gsd-assess script..." -ForegroundColor Yellow

$assessScript = @'
<#
.SYNOPSIS
    GSD Assess - Standalone codebase assessment with file map.
    Run BEFORE gsd-blueprint or gsd-converge on any repo.

.DESCRIPTION
    1. Generates a complete file map of the repo (file-map.json + file-map-tree.md)
    2. Uses Claude Code to analyze existing code against specs
    3. Updates file map after assessment
    The file map is maintained across iterations so agents always
    know the current repo structure.

.USAGE
    cd C:\path\to\repo
    gsd-assess                  # full assessment
    gsd-assess -DryRun          # preview
    gsd-assess -MapOnly         # just regenerate file map
#>

param(
    [switch]$DryRun,
    [switch]$MapOnly
)

$ErrorActionPreference = "Continue"
$RepoRoot = (Get-Location).Path
$UserHome = $env:USERPROFILE
$GlobalDir = Join-Path $UserHome ".gsd-global"
$GsdDir = Join-Path $RepoRoot ".gsd"
$AssessDir = Join-Path $GsdDir "assessment"

# Validate
if (-not (Test-Path $GlobalDir)) {
    Write-Host "[XX] GSD not installed. Run installers first." -ForegroundColor Red
    exit 1
}

# Create dirs
@($GsdDir, $AssessDir, "$GsdDir\logs") | ForEach-Object {
    if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
}

# ================================================================
# FILE MAP GENERATOR
# Scans entire repo. Agents use this as spatial awareness.
# Updated after every iteration to stay current.
# ================================================================

function Update-FileMap {
    param(
        [string]$Root,
        [string]$GsdPath
    )

    $mapPath = Join-Path $GsdPath "file-map.json"
    $treePath = Join-Path $GsdPath "file-map-tree.md"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    Write-Host "  Generating file map..." -ForegroundColor Cyan

    # Exclusions
    $excludePattern = '(node_modules|\.git[\\\/]|[\\\/]bin[\\\/]|[\\\/]obj[\\\/]|packages|dist[\\\/]|build[\\\/]|\.gsd|\.vs[\\\/]|\.vscode|\.tmp-bin|TestResults|coverage|__pycache__|\.next|\.nuxt)'

    $allFiles = @(Get-ChildItem -Path $Root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch $excludePattern })

    # Build directory stats
    $dirTree = @{}
    $fileEntries = @()
    $extSummary = @{}

    foreach ($file in $allFiles) {
        $relPath = $file.FullName.Substring($Root.Length).TrimStart('\')
        $relDir = Split-Path $relPath -Parent
        if (-not $relDir) { $relDir = "(root)" }
        $ext = $file.Extension.ToLower()

        $fileEntries += @{
            path = $relPath
            dir = $relDir
            name = $file.Name
            ext = $ext
            size = $file.Length
            modified = $file.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
        }

        # Directory accumulator
        if (-not $dirTree.ContainsKey($relDir)) {
            $dirTree[$relDir] = @{ files = 0; total_size = 0; extensions = @{} }
        }
        $dirTree[$relDir].files++
        $dirTree[$relDir].total_size += $file.Length
        if ($ext) {
            if (-not $dirTree[$relDir].extensions.ContainsKey($ext)) {
                $dirTree[$relDir].extensions[$ext] = 0
            }
            $dirTree[$relDir].extensions[$ext]++
        }

        # Extension accumulator
        if ($ext) {
            if (-not $extSummary.ContainsKey($ext)) {
                $extSummary[$ext] = @{ count = 0; total_size = 0 }
            }
            $extSummary[$ext].count++
            $extSummary[$ext].total_size += $file.Length
        }
    }

    $totalSize = ($allFiles | Measure-Object -Property Length -Sum).Sum
    if (-not $totalSize) { $totalSize = 0 }

    # Write JSON map
    $fileMap = @{
        generated = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        repo_root = $Root
        total_files = $fileEntries.Count
        total_dirs = $dirTree.Count
        total_size_bytes = $totalSize
        extensions = $extSummary
        directories = $dirTree
        files = $fileEntries
    }
    $json = $fileMap | ConvertTo-Json -Depth 5 -Compress
    Set-Content -Path $mapPath -Value $json -Encoding UTF8

    # Write human-readable tree
    $treeLines = @(
        "# Repository File Map"
        "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "Total: $($fileEntries.Count) files in $($dirTree.Count) directories"
        "Size: $([math]::Round($totalSize / 1MB, 2)) MB"
        ""
        "## File Types"
        ""
    )
    $sortedExts = $extSummary.GetEnumerator() | Sort-Object { $_.Value.count } -Descending
    foreach ($e in $sortedExts) {
        $kb = [math]::Round($e.Value.total_size / 1024, 1)
        $treeLines += "- $($e.Key): $($e.Value.count) files ($kb KB)"
    }
    $treeLines += ""
    $treeLines += "## Directory Structure"
    $treeLines += ""

    $sortedDirs = $dirTree.GetEnumerator() | Sort-Object Name
    foreach ($d in $sortedDirs) {
        $depth = ($d.Key.Split('\') | Where-Object { $_ }).Count - 1
        if ($depth -lt 0) { $depth = 0 }
        $prefix = "  " * $depth
        $dirName = Split-Path $d.Key -Leaf
        if (-not $dirName) { $dirName = $d.Key }
        $extList = ($d.Value.extensions.GetEnumerator() |
            Sort-Object { $_.Value } -Descending |
            ForEach-Object { "$($_.Key):$($_.Value)" }) -join ", "
        $treeLines += "$prefix- $dirName\ ($($d.Value.files) files: $extList)"
    }

    Set-Content -Path $treePath -Value ($treeLines -join "`n") -Encoding UTF8

    $sw.Stop()
    Write-Host "  [OK] File map: $($fileEntries.Count) files, $($dirTree.Count) dirs ($([math]::Round($sw.Elapsed.TotalSeconds, 1))s)" -ForegroundColor DarkGreen
    Write-Host "    $mapPath" -ForegroundColor DarkGray
    Write-Host "    $treePath" -ForegroundColor DarkGray

    return $mapPath
}

# ================================================================
# INTERFACE DETECTION
# ================================================================

$interfaceLib = "$GlobalDir\lib\modules\interfaces.ps1"
$detectedInterfaces = @()
if (Test-Path $interfaceLib) {
    . $interfaceLib
    $detectedInterfaces = Initialize-ProjectInterfaces -RepoRoot $RepoRoot
}

# Load resilience if available
$resilienceLib = "$GlobalDir\lib\modules\resilience.ps1"
if (Test-Path $resilienceLib) { . $resilienceLib }

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  GSD Codebase Assessment - Multi-Interface" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan

if ($detectedInterfaces.Count -gt 0 -and (Get-Command Show-InterfaceSummary -ErrorAction SilentlyContinue)) {
    Show-InterfaceSummary -Interfaces $detectedInterfaces
} else {
    Write-Host "  [!!]  No design interfaces detected" -ForegroundColor DarkYellow
    Write-Host "  Expected: design\web\v##, design\mcp\v##, etc." -ForegroundColor DarkGray
}

# Count source files
$existingFiles = @(Get-ChildItem -Path $RepoRoot -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object {
        $_.FullName -notmatch '(node_modules|\.git|bin[\\\/]|obj[\\\/]|packages|dist|build|\.gsd)' -and
        $_.Extension -match '\.(cs|sql|tsx?|jsx?|css|scss|json|md|html|xml|yaml|yml|csproj|sln)$'
    })

Write-Host "  $($existingFiles.Count) source files to assess" -ForegroundColor White
$typeGroups = $existingFiles | Group-Object Extension | Sort-Object Count -Descending | Select-Object -First 8
foreach ($g in $typeGroups) {
    Write-Host "     $($g.Name): $($g.Count)" -ForegroundColor DarkGray
}

# ================================================================
# GENERATE FILE MAP (always, before anything else)
# ================================================================
Write-Host ""
$fileMapPath = Update-FileMap -Root $RepoRoot -GsdPath $GsdDir

if ($MapOnly) {
    Write-Host ""
    Write-Host "  [OK] File map updated (MapOnly mode)" -ForegroundColor Green
    exit 0
}

# ================================================================
# RUN CLAUDE ASSESSMENT
# ================================================================

$promptPath = "$GlobalDir\prompts\claude\assess.md"
if (-not (Test-Path $promptPath)) {
    Write-Host "[XX] Assessment prompt not found." -ForegroundColor Red
    exit 1
}

$prompt = (Get-Content $promptPath -Raw).Replace("{{REPO_ROOT}}", $RepoRoot).Replace("{{GSD_DIR}}", $GsdDir)

# Add interface context
if ($detectedInterfaces.Count -gt 0 -and (Get-Command Build-InterfacePromptContext -ErrorAction SilentlyContinue)) {
    $ifaceCtx = Build-InterfacePromptContext -Interfaces $detectedInterfaces
    $prompt = $prompt.Replace("{{INTERFACE_CONTEXT}}", $ifaceCtx)
} else {
    $prompt = $prompt.Replace("{{INTERFACE_CONTEXT}}", "(No design interfaces detected)")
}

# Inject file map reference
$prompt += "`n`n## File Map`nA complete file map of the repository is available at:`n- JSON: $fileMapPath`n- Tree: $GsdDir\file-map-tree.md`nRead the tree file first to understand the full repo structure before analyzing code.`n"

if (-not $DryRun) {
    Write-Host ""
    Write-Host "[SEARCH] Running assessment..." -ForegroundColor Cyan

    $startTime = Get-Date

    if (Get-Command Invoke-WithRetry -ErrorAction SilentlyContinue) {
        $result = Invoke-WithRetry -Agent "claude" -Prompt $prompt -Phase "assess" -GsdDir $GsdDir
        if (-not $result.Success) {
            Write-Host "  [XX] Assessment failed: $($result.Error)" -ForegroundColor Red
        }
    } else {
        claude -p $prompt --allowedTools "Read,Write,Edit,Bash,mcp__*" 2>&1 |
            Tee-Object "$GsdDir\logs\assessment.log"
    }

    $elapsed = (Get-Date) - $startTime

    # Update file map AFTER assessment (Claude may have created files)
    Write-Host ""
    Write-Host "  Refreshing file map post-assessment..." -ForegroundColor DarkGray
    $null = Update-FileMap -Root $RepoRoot -GsdPath $GsdDir

    Write-Host ""
    Write-Host "[TIME]  Assessment took: $([math]::Round($elapsed.TotalMinutes, 1)) minutes" -ForegroundColor DarkGray

    # Display results
    $summaryFile = Join-Path $AssessDir "assessment-summary.md"
    if (Test-Path $summaryFile) {
        Write-Host ""
        Write-Host "=== Assessment Summary ===" -ForegroundColor Green
        Get-Content $summaryFile | ForEach-Object { Write-Host "  $_" -ForegroundColor White }
    }

    $classFile = Join-Path $AssessDir "work-classification.json"
    if (Test-Path $classFile) {
        $work = Get-Content $classFile -Raw | ConvertFrom-Json
        Write-Host ""
        Write-Host "  Work Breakdown:" -ForegroundColor Yellow
        Write-Host "    [OK] Skip (done):    $($work.summary.skip)" -ForegroundColor Green
        Write-Host "    [!!] Refactor:       $($work.summary.refactor)" -ForegroundColor DarkYellow
        Write-Host "    [->] Extend:         $($work.summary.extend)" -ForegroundColor Cyan
        Write-Host "    [++] Build new:      $($work.summary.build_new)" -ForegroundColor Magenta
    }

    Write-Host ""
    Write-Host "  Output:" -ForegroundColor DarkGray
    Write-Host "    .gsd\assessment\        Assessment results" -ForegroundColor DarkGray
    Write-Host "    .gsd\file-map.json      Complete repo inventory" -ForegroundColor DarkGray
    Write-Host "    .gsd\file-map-tree.md   Human-readable tree" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  NEXT:" -ForegroundColor Yellow
    Write-Host "    gsd-blueprint    Uses assessment + file map for blueprint" -ForegroundColor White
    Write-Host "    gsd-converge     Uses assessment + file map for convergence" -ForegroundColor White
    Write-Host ""
} else {
    Write-Host ""
    Write-Host "  [DRY RUN] Would assess $($existingFiles.Count) files" -ForegroundColor DarkYellow
    Write-Host "  File map generated at: $fileMapPath" -ForegroundColor DarkGray
    Write-Host ""
}
'@

Set-Content -Path "$BlueprintDir\scripts\assess.ps1" -Value $assessScript -Encoding UTF8
Write-Host "   [OK] scripts\assess.ps1" -ForegroundColor DarkGreen

Write-Host ""

# ========================================================
# STEP 5: Add gsd-assess to global commands
# ========================================================

Write-Host "Adding gsd-assess command..." -ForegroundColor Yellow

# CMD wrapper
$binDir = Join-Path $GsdGlobalDir "bin"
if (-not (Test-Path $binDir)) { New-Item -ItemType Directory -Path $binDir -Force | Out-Null }

$assessCmd = @"
@echo off
powershell -ExecutionPolicy Bypass -File "%USERPROFILE%\.gsd-global\blueprint\scripts\assess.ps1" %*
"@
Set-Content -Path "$binDir\gsd-assess.cmd" -Value $assessCmd -Encoding ASCII
Write-Host "   [OK] bin\gsd-assess.cmd" -ForegroundColor DarkGreen

# Profile function
$assessFunction = @'

function gsd-assess {
    param([switch]$DryRun)
    $params = @{}
    if ($DryRun) { $params.DryRun = $true }
    & "$env:USERPROFILE\.gsd-global\blueprint\scripts\assess.ps1" @params
}
'@

$profileFile = Join-Path $GsdGlobalDir "scripts\gsd-profile-functions.ps1"
if (Test-Path $profileFile) {
    $existing = Get-Content $profileFile -Raw
    if ($existing -match "function gsd-assess") {
        # Replace existing assess function
        $existing = $existing -replace '(?s)function gsd-assess[^}]*\}', ''
        Set-Content -Path $profileFile -Value $existing.TrimEnd() -Encoding UTF8
    }
    Add-Content -Path $profileFile -Value $assessFunction -Encoding UTF8
    Write-Host "   [OK] Updated gsd-assess in profile functions" -ForegroundColor DarkGreen
} else {
    Set-Content -Path $profileFile -Value $assessFunction -Encoding UTF8
    Write-Host "   [OK] Created profile with gsd-assess" -ForegroundColor DarkGreen
}

Write-Host ""

# ========================================================
# STEP 6: Update blueprint prompt to reference partial guide
# ========================================================

Write-Host "[MEMO] Updating blueprint prompt to reference partial-repo guide..." -ForegroundColor Yellow

$blueprintPromptFile = "$BlueprintDir\prompts\claude\blueprint.md"
if (Test-Path $blueprintPromptFile) {
    $existing = Get-Content $blueprintPromptFile -Raw
    if ($existing -notmatch "partial-repo-guide") {
        $appendix = @"

## Partial Repo Handling
ALSO READ: {{GSD_DIR}}\..\..\.gsd-global\blueprint\prompts\claude\partial-repo-guide.md
If the repo already has code, you MUST follow the partial-repo guide for:
- Setting correct initial statuses (completed, partial, refactor, not_started)
- Adding partial_notes and preserve fields
- Ordering work types within tiers (refactor -> extend -> build_new)
- Writing pre-assessment.json

If an assessment exists at {{GSD_DIR}}\assessment\, READ IT FIRST.
Use the work-classification.json and detected-patterns.json to inform your blueprint.
"@
        Add-Content -Path $blueprintPromptFile -Value $appendix -Encoding UTF8
        Write-Host "   [OK] Updated blueprint prompt" -ForegroundColor DarkGreen
    } else {
        Write-Host "   [>>]  Blueprint prompt already patched" -ForegroundColor DarkGray
    }
} else {
    Write-Host "   [!!]  Blueprint prompt not found - install gsd-blueprint first" -ForegroundColor DarkYellow
}

# Update Codex build prompt to reference partial guide
$buildPromptFile = "$BlueprintDir\prompts\codex\build.md"
if (Test-Path $buildPromptFile) {
    $existing = Get-Content $buildPromptFile -Raw
    if ($existing -notmatch "partial-repo-guide") {
        $appendix = @"

## Partial Repo Handling
ALSO READ: {{GSD_DIR}}\..\..\.gsd-global\blueprint\prompts\codex\partial-repo-guide.md
If blueprint items have status "partial", "refactor", or "extend", you MUST follow
the partial-repo guide. Key rules:
- READ existing files before modifying them
- PRESERVE interfaces and contracts listed in the preserve array
- For refactors: create stored procedures BEFORE rewriting repositories
- NEVER delete files without creating replacements first
- Check import dependencies before changing any exports
"@
        Add-Content -Path $buildPromptFile -Value $appendix -Encoding UTF8
        Write-Host "   [OK] Updated Codex build prompt" -ForegroundColor DarkGreen
    } else {
        Write-Host "   [>>]  Codex build prompt already patched" -ForegroundColor DarkGray
    }
} else {
    Write-Host "   [!!]  Codex build prompt not found - install gsd-blueprint first" -ForegroundColor DarkYellow
}

Write-Host ""

# ========================================================
# DONE
# ========================================================

Write-Host "=========================================================" -ForegroundColor Green
Write-Host "  [OK] Partial Repo Patch Applied" -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  NEW COMMAND:" -ForegroundColor Yellow
Write-Host "    gsd-assess                      # analyze partial repo before building" -ForegroundColor Cyan
Write-Host ""
Write-Host "  RECOMMENDED WORKFLOW FOR PARTIAL REPOS:" -ForegroundColor Yellow
Write-Host ""
Write-Host "    cd C:\projects\partially-built-app" -ForegroundColor DarkGray
Write-Host ""
Write-Host "    Step 1:  gsd-assess              # understand what exists" -ForegroundColor White
Write-Host "             Review .gsd\assessment\  # check the analysis" -ForegroundColor DarkGray
Write-Host ""
Write-Host "    Step 2:  gsd-blueprint            # generates partial-aware blueprint" -ForegroundColor White
Write-Host "             Items already done -> status: completed (skipped)" -ForegroundColor DarkGray
Write-Host "             Wrong patterns   -> status: refactor (rewritten)" -ForegroundColor DarkGray
Write-Host "             Incomplete items -> status: extend (completed)" -ForegroundColor DarkGray
Write-Host "             Missing items    -> status: not_started (built)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "    Step 3:  gsd-converge             # ongoing maintenance after 100%" -ForegroundColor White
Write-Host ""
Write-Host "  UPDATED FILES:" -ForegroundColor Yellow
Write-Host "    prompts\claude\assess.md               Assessment prompt" -ForegroundColor DarkGray
Write-Host "    prompts\claude\partial-repo-guide.md   Blueprint partial guide" -ForegroundColor DarkGray
Write-Host "    prompts\codex\partial-repo-guide.md    Codex partial guide" -ForegroundColor DarkGray
Write-Host "    blueprint\prompts\claude\blueprint.md  Patched with partial ref" -ForegroundColor DarkGray
Write-Host "    blueprint\prompts\codex\build.md       Patched with partial ref" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  [!!]  RESTART YOUR TERMINAL for gsd-assess command" -ForegroundColor Yellow
Write-Host ""
