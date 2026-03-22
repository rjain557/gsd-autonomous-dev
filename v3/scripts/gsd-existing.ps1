<#
.SYNOPSIS
    GSD V3 Existing Codebase Verification Entry Point
.DESCRIPTION
    For repos with EXISTING code that needs verification against specs.
    Not greenfield generation — this reads actual code, extracts granular requirements
    from specs, maps code to features, and marks satisfaction before handing off to
    the convergence pipeline for any remaining work.

    Usage:
      pwsh -File gsd-existing.ps1 -RepoRoot "C:\repos\project"
      pwsh -File gsd-existing.ps1 -RepoRoot "C:\repos\project" -SkipSpecGate
      pwsh -File gsd-existing.ps1 -RepoRoot "C:\repos\project" -DeepVerify:$false
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [string]$NtfyTopic = "auto",
    [switch]$SkipSpecGate,
    [switch]$DeepVerify = $true,
    [int]$StartIteration = 1
)

$ErrorActionPreference = "Stop"

$v3Dir = Split-Path $PSScriptRoot -Parent
$RepoRoot = (Resolve-Path $RepoRoot).Path
$GsdDir = Join-Path $RepoRoot ".gsd"

# ============================================================
# CENTRALIZED LOGGING — logs stored in ~/.gsd-global/logs/{repo-name}/
# Each pipeline run gets a run log, each iteration gets its own log
# Iteration counter is persistent per-repo (survives across runs)
# ============================================================

$repoName = Split-Path $RepoRoot -Leaf
$globalLogDir = Join-Path $env:USERPROFILE ".gsd-global/logs/$repoName"
if (-not (Test-Path $globalLogDir)) { New-Item -ItemType Directory -Path $globalLogDir -Force | Out-Null }

# Also keep local logs dir for backwards compatibility
$localLogDir = Join-Path $v3Dir "../logs"
if (-not (Test-Path $localLogDir)) { New-Item -ItemType Directory -Path $localLogDir -Force | Out-Null }

# Persistent iteration counter per repo (never resets between runs)
$iterCounterFile = Join-Path $globalLogDir "iteration-counter.json"
if (Test-Path $iterCounterFile) {
    $iterCounter = Get-Content $iterCounterFile -Raw | ConvertFrom-Json
    $globalIterationStart = $iterCounter.next_iteration
} else {
    $globalIterationStart = 1
    @{ next_iteration = 1; repo = $repoName; repo_root = $RepoRoot; created = (Get-Date -Format "o") } |
        ConvertTo-Json | Set-Content $iterCounterFile -Encoding UTF8
}

# If user specified StartIteration, use that; otherwise use the persistent counter
if ($StartIteration -gt 1) {
    $globalIterationStart = $StartIteration
}

# Pipeline run log (one per pipeline start)
$timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$runId = "run-$timestamp"
$runLogFile = Join-Path $globalLogDir "$runId.log"

# Also write to local logs for backwards compat
$localTranscript = Join-Path $localLogDir "v3-pipeline-$timestamp.log"

# Per-iteration log directory
$iterLogDir = Join-Path $globalLogDir "iterations"
if (-not (Test-Path $iterLogDir)) { New-Item -ItemType Directory -Path $iterLogDir -Force | Out-Null }

# Latest log pointer (both local and global)
$latestLog = Join-Path $v3Dir "../v3-pipeline-live.log"
$globalLatestLog = Join-Path $globalLogDir "latest.log"

try { Stop-Transcript -EA SilentlyContinue } catch {}
Start-Transcript -Path $localTranscript | Out-Null

# Write run log header
$runHeader = @{
    run_id                    = $runId
    repo                      = $repoName
    repo_root                 = $RepoRoot
    started_at                = (Get-Date -Format "o")
    global_iteration_start    = $globalIterationStart
    mode                      = "existing_codebase"
    deep_verify               = [bool]$DeepVerify
    skip_spec_gate            = [bool]$SkipSpecGate
    log_file                  = $runLogFile
    local_log                 = $localTranscript
    iteration_log_dir         = $iterLogDir
}
$runHeader | ConvertTo-Json | Set-Content $runLogFile -Encoding UTF8

# Update latest pointers
Set-Content $latestLog -Value "# Latest log: $localTranscript`n# Started: $(Get-Date)`n# Run ID: $runId`n# Mode: existing_codebase`n# Global iter start: $globalIterationStart" -Encoding UTF8
Copy-Item $latestLog $globalLatestLog -Force -ErrorAction SilentlyContinue

Write-Host "  [LOG] Central: $globalLogDir" -ForegroundColor DarkGray
Write-Host "  [LOG] Run: $runId | Global iteration: $globalIterationStart" -ForegroundColor DarkGray

# Export for phase-orchestrator to use
$env:GSD_GLOBAL_LOG_DIR = $globalLogDir
$env:GSD_ITER_LOG_DIR = $iterLogDir
$env:GSD_GLOBAL_ITER_START = $globalIterationStart
$env:GSD_ITER_COUNTER_FILE = $iterCounterFile
$env:GSD_RUN_ID = $runId
$env:GSD_REPO_NAME = $repoName

# Always clear stale lock file on startup
$lockFile = Join-Path $GsdDir ".gsd-lock.json"
if (Test-Path $lockFile) {
    Remove-Item $lockFile -Force
    Write-Host "  [LOCK] Cleared stale lock file" -ForegroundColor Yellow
}

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  GSD V3 - Existing Codebase Verification" -ForegroundColor Cyan
Write-Host "  Repo: $RepoRoot" -ForegroundColor DarkGray
Write-Host "  Log: $localTranscript" -ForegroundColor DarkGray
Write-Host "  DeepVerify: $DeepVerify | SkipSpecGate: $SkipSpecGate" -ForegroundColor DarkGray
Write-Host "  Global iter: $globalIterationStart" -ForegroundColor DarkGray
Write-Host "============================================" -ForegroundColor Cyan

# Load modules
$modulesDir = Join-Path $v3Dir "lib/modules"
. (Join-Path $modulesDir "api-client.ps1")
. (Join-Path $modulesDir "cost-tracker.ps1")
. (Join-Path $modulesDir "local-validator.ps1")
. (Join-Path $modulesDir "resilience.ps1")
. (Join-Path $modulesDir "supervisor.ps1")
. (Join-Path $modulesDir "traceability-updater.ps1")
. (Join-Path $modulesDir "phase-orchestrator.ps1")

# Load config
$Config = Get-Content (Join-Path $v3Dir "config/global-config.json") -Raw | ConvertFrom-Json
$AgentMap = Get-Content (Join-Path $v3Dir "config/agent-map.json") -Raw | ConvertFrom-Json

# ============================================================
# EXISTING CODEBASE MODE CONFIG
# Injected into Config so pipeline phases can read it
# ============================================================
$existingCodebaseConfig = @{
    deep_extraction           = $true
    code_inventory_on_start   = $true
    verify_by_reading_code    = [bool]$DeepVerify
    skip_satisfied_in_execute = $true
}

# Attach to Config as a dynamic property for downstream phases
$Config | Add-Member -NotePropertyName "existing_codebase_mode" -NotePropertyValue $existingCodebaseConfig -Force

# Ensure .gsd directories exist
$reqDir = Join-Path $GsdDir "requirements"
$cacheDir = Join-Path $GsdDir "cache"
$costsDir = Join-Path $GsdDir "costs"
foreach ($dir in @($GsdDir, $reqDir, $cacheDir, $costsDir)) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

# ============================================================
# PHASE 0: PRE-FLIGHT + FILE INVENTORY + CACHE WARM
# (Same as gsd-update.ps1 — reuse orchestrator functions)
# ============================================================

Write-Host "`n--- Pre-flight ---" -ForegroundColor Yellow
$preflight = Test-PreFlightV3 -RepoRoot $RepoRoot -GsdDir $GsdDir -Mode "feature_update"
if (-not $preflight) {
    Write-Host "  [XX] Pre-flight failed. Fix issues above." -ForegroundColor Red
    try { Stop-Transcript -EA SilentlyContinue } catch {}
    exit 1
}

Write-Host "`n--- File Inventory ---" -ForegroundColor Yellow
$inventory = Build-FileInventory -RepoRoot $RepoRoot -GsdDir $GsdDir

Write-Host "`n--- Building Cache Prefix ---" -ForegroundColor Yellow
$specContext = Build-SpecContext -RepoRoot $RepoRoot -GsdDir $GsdDir -Inventory $inventory
Write-Host "  Spec context: $($specContext.Length) chars" -ForegroundColor DarkGray
$blueprintContext = Build-BlueprintContext -RepoRoot $RepoRoot -GsdDir $GsdDir -Inventory $inventory
Write-Host "  Blueprint context: $($blueprintContext.Length) chars" -ForegroundColor DarkGray

$systemPromptPath = Join-Path $v3Dir "prompts/shared/system-prompt.md"
$systemPrompt = if (Test-Path $systemPromptPath) { Get-Content $systemPromptPath -Raw -Encoding UTF8 } else { "You are GSD, an autonomous software development system." }

$cacheBlocks = @(
    @{ text = $systemPrompt; cache = $true; name = "system_prompt" }
    @{ text = $specContext; cache = $true; name = "spec_documents" }
    @{ text = $blueprintContext; cache = $true; name = "blueprint_manifest" }
)

# Initialize cost tracking early (needed for pre-pipeline API calls)
Initialize-CostTracker -Mode "feature_update" -BudgetCap $Config.pipeline_modes.feature_update.budget_cap_usd -GsdDir $GsdDir

# Cache warm
Write-Host "`n--- Cache Warm ---" -ForegroundColor Yellow
$warmResult = Invoke-CacheWarmup -CacheBlocks $cacheBlocks
if ($warmResult.Usage) {
    Add-ApiCallCost -Model "claude-sonnet-4-6" -Usage $warmResult.Usage -Phase "cache-warm"
}

# ============================================================
# PHASE 1: SPEC GATE (with higher token limit for existing codebases)
# ============================================================

if (-not $SkipSpecGate) {
    Write-Host "`n--- Spec Gate (existing codebase, extended) ---" -ForegroundColor Yellow
    $specGateResult = Invoke-SpecGatePhase -GsdDir $GsdDir -RepoRoot $RepoRoot `
        -CacheBlocks $cacheBlocks -Config $Config -Mode "feature_update" -Inventory $inventory

    if ($specGateResult.Blocked) {
        Write-Host "  [BLOCKED] Spec gate blocked pipeline. Fix spec issues first." -ForegroundColor Red
        try { Stop-Transcript -EA SilentlyContinue } catch {}
        exit 1
    }
} else {
    Write-Host "`n--- Spec Gate: SKIPPED (user override) ---" -ForegroundColor Yellow
}

# ============================================================
# PHASE 1b: SPEC ALIGNMENT (drift detection)
# ============================================================

Write-Host "`n--- Spec Alignment ---" -ForegroundColor Yellow
$specAlignResult = Invoke-SpecAlignmentPhase -GsdDir $GsdDir -RepoRoot $RepoRoot `
    -CacheBlocks $cacheBlocks -Config $Config -Inventory $inventory

if ($specAlignResult.Blocked) {
    # In existing codebase mode, drift is expected — that's what the pipeline is here to fix.
    # Log the drift but don't block. The convergence loop will close the gaps.
    Write-Host "  [DRIFT] Spec alignment drift detected — convergence pipeline will address gaps." -ForegroundColor Yellow
    Write-Host "  [DRIFT] Pipeline will continue to fix drift through iterations." -ForegroundColor DarkGray
}

# ============================================================
# PHASE 2: DEEP REQUIREMENTS EXTRACTION
# Calls Sonnet to read ALL spec docs and extract granular requirements.
# Uses 32K max tokens. Saves to .gsd/requirements/requirements-matrix.json
# ============================================================

Write-Host "`n============================================" -ForegroundColor Magenta
Write-Host "  DEEP REQUIREMENTS EXTRACTION" -ForegroundColor Magenta
Write-Host "============================================" -ForegroundColor Magenta

$matrixPath = Join-Path $reqDir "requirements-matrix.json"
$existingMatrix = $null
if (Test-Path $matrixPath) {
    $existingMatrix = Get-Content $matrixPath -Raw | ConvertFrom-Json
    Write-Host "  Existing matrix found: $($existingMatrix.requirements.Count) requirements" -ForegroundColor DarkGray
}

# Build comprehensive spec content for extraction
$specFiles = @()
$specDirs = @("docs", "specs", "design", "requirements")
foreach ($sd in $specDirs) {
    $sdPath = Join-Path $RepoRoot $sd
    if (Test-Path $sdPath) {
        $found = Get-ChildItem -Path $sdPath -Recurse -Include "*.md","*.txt","*.json","*.yaml","*.yml" -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -lt 500KB -and $_.FullName -notmatch "node_modules|\.gsd|_analysis" }
        $specFiles += $found
    }
}

Write-Host "  Spec files found: $($specFiles.Count)" -ForegroundColor DarkGray

if ($specFiles.Count -eq 0) {
    Write-Host "  [WARN] No spec files found in docs/, specs/, design/, requirements/" -ForegroundColor Yellow
    Write-Host "  Proceeding with code-only inventory..." -ForegroundColor Yellow
}

$specContent = ""
foreach ($sf in $specFiles) {
    $relPath = $sf.FullName.Replace($RepoRoot, "").TrimStart("\", "/")
    $fileContent = Get-Content $sf.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($fileContent) {
        $specContent += "`n--- FILE: $relPath ---`n$fileContent`n"
    }
}

# Truncate if too large (keep under ~100K chars for prompt)
if ($specContent.Length -gt 100000) {
    $specContent = $specContent.Substring(0, 100000) + "`n... [TRUNCATED — $($specContent.Length) chars total]"
    Write-Host "  [WARN] Spec content truncated to 100K chars" -ForegroundColor Yellow
}

$extractionPrompt = @"
You are analyzing an EXISTING codebase's specification documents to extract granular, testable requirements.

## Instructions
1. Read ALL spec documents below carefully
2. Extract every distinct requirement — functional, non-functional, UI, API, data, security, compliance
3. Each requirement must be granular enough to verify against a single file or small set of files
4. Assign unique IDs: REQ-001, REQ-002, etc.
5. Categorize: ui, api, data, security, compliance, config, integration, testing
6. Mark all as "not_started" — the next phase will verify against actual code

## Output Format (JSON only)
{
  "requirements": [
    {
      "id": "REQ-001",
      "text": "Descriptive requirement text",
      "category": "ui|api|data|security|compliance|config|integration|testing",
      "priority": "critical|high|medium|low",
      "source": "spec filename or section",
      "status": "not_started",
      "target_files": [],
      "acceptance_criteria": ["criterion 1", "criterion 2"]
    }
  ],
  "metadata": {
    "total_requirements": 0,
    "extraction_date": "$(Get-Date -Format 'yyyy-MM-dd')",
    "spec_files_analyzed": $($specFiles.Count),
    "mode": "existing_codebase"
  }
}

## Spec Documents
$specContent
"@

Write-Host "  Calling Sonnet for deep extraction (32K max tokens)..." -ForegroundColor Cyan
$extractResult = Invoke-SonnetApi -Prompt $extractionPrompt -MaxTokens 32000 `
    -CacheBlocks $cacheBlocks -SystemPrompt "Extract granular requirements from specs. Return ONLY valid JSON."

if ($extractResult.Success -and $extractResult.Content) {
    Add-ApiCallCost -Model "claude-sonnet-4-6" -Usage $extractResult.Usage -Phase "deep-extraction"

    try {
        $extractedMatrix = $extractResult.Content | ConvertFrom-Json
        $reqCount = $extractedMatrix.requirements.Count
        Write-Host "  [OK] Extracted $reqCount requirements from specs" -ForegroundColor Green

        # Save the matrix
        $extractedMatrix | ConvertTo-Json -Depth 10 | Set-Content $matrixPath -Encoding UTF8
        Write-Host "  [OK] Saved to $matrixPath" -ForegroundColor Green
    }
    catch {
        Write-Host "  [ERR] Failed to parse extraction response: $($_.Exception.Message)" -ForegroundColor Red
        if (-not $existingMatrix) {
            Write-Host "  [FATAL] No existing matrix and extraction failed. Aborting." -ForegroundColor Red
            try { Stop-Transcript -EA SilentlyContinue } catch {}
            exit 1
        }
        Write-Host "  [WARN] Using existing matrix as fallback" -ForegroundColor Yellow
    }
} else {
    Write-Host "  [ERR] Sonnet API call failed: $($extractResult.Error)" -ForegroundColor Red
    if (-not $existingMatrix) {
        Write-Host "  [FATAL] No existing matrix and extraction failed. Aborting." -ForegroundColor Red
        try { Stop-Transcript -EA SilentlyContinue } catch {}
        exit 1
    }
    Write-Host "  [WARN] Using existing matrix as fallback" -ForegroundColor Yellow
}

# ============================================================
# PHASE 3: CODE INVENTORY
# Scans codebase, builds file->feature map, detects stubs
# ============================================================

Write-Host "`n============================================" -ForegroundColor Magenta
Write-Host "  CODE INVENTORY" -ForegroundColor Magenta
Write-Host "============================================" -ForegroundColor Magenta

# Build a summary of all source files with their sizes and key patterns
$codeExtensions = @("*.cs", "*.ts", "*.tsx", "*.js", "*.jsx", "*.sql", "*.css", "*.scss", "*.html", "*.json", "*.yaml", "*.yml", "*.ps1", "*.py")
$excludeDirs = @("node_modules", "bin", "obj", "dist", "build", ".vs", ".idea", ".gsd", ".git", "packages")
$codeFiles = @()

foreach ($ext in $codeExtensions) {
    $found = Get-ChildItem -Path $RepoRoot -Recurse -Filter $ext -ErrorAction SilentlyContinue |
        Where-Object {
            $path = $_.FullName
            $excluded = $false
            foreach ($ex in $excludeDirs) {
                if ($path -match [regex]::Escape("\$ex\")) { $excluded = $true; break }
            }
            -not $excluded -and $_.Length -lt 1MB
        }
    $codeFiles += $found
}

Write-Host "  Source files found: $($codeFiles.Count)" -ForegroundColor DarkGray

# Build file summary for LLM analysis
$fileSummary = @()
$totalLines = 0
foreach ($cf in $codeFiles) {
    $relPath = $cf.FullName.Replace($RepoRoot, "").TrimStart("\", "/")
    $lineCount = (Get-Content $cf.FullName -ErrorAction SilentlyContinue | Measure-Object -Line).Lines
    $totalLines += $lineCount

    # Detect stubs: files with very few lines relative to their type
    $isStub = $false
    if ($cf.Extension -in @(".cs", ".ts", ".tsx") -and $lineCount -lt 10) { $isStub = $true }
    if ($cf.Extension -eq ".sql" -and $lineCount -lt 5) { $isStub = $true }

    $fileSummary += @{
        path      = $relPath
        extension = $cf.Extension
        lines     = $lineCount
        size_kb   = [math]::Round($cf.Length / 1024, 1)
        is_stub   = $isStub
    }
}

$stubCount = ($fileSummary | Where-Object { $_.is_stub }).Count
Write-Host "  Total lines: $totalLines | Stubs detected: $stubCount" -ForegroundColor DarkGray

# Save code inventory
$codeInventoryPath = Join-Path $GsdDir "code-inventory.json"
$codeInventory = @{
    generated_at = (Get-Date -Format "o")
    repo_root    = $RepoRoot
    total_files  = $codeFiles.Count
    total_lines  = $totalLines
    stub_count   = $stubCount
    files        = $fileSummary
}
$codeInventory | ConvertTo-Json -Depth 5 | Set-Content $codeInventoryPath -Encoding UTF8
Write-Host "  [OK] Code inventory saved to $codeInventoryPath" -ForegroundColor Green

# ============================================================
# PHASE 4: SATISFACTION VERIFICATION
# For each requirement, checks if code implements it.
# Marks SATISFIED / PARTIAL / NOT_STARTED
# ============================================================

Write-Host "`n============================================" -ForegroundColor Magenta
Write-Host "  SATISFACTION VERIFICATION" -ForegroundColor Magenta
Write-Host "============================================" -ForegroundColor Magenta

# Re-read matrix (may have been written by extraction phase)
$matrix = Get-Content $matrixPath -Raw | ConvertFrom-Json
$reqCount = $matrix.requirements.Count
Write-Host "  Verifying $reqCount requirements against codebase..." -ForegroundColor Cyan

# Build file listing for the LLM (compact format)
$fileListCompact = ($fileSummary | ForEach-Object { "$($_.path) ($($_.lines)L)" }) -join "`n"
if ($fileListCompact.Length -gt 30000) {
    $fileListCompact = $fileListCompact.Substring(0, 30000) + "`n... [TRUNCATED]"
}

# Build code snippets for deep verify mode
$codeSnippets = ""
if ($DeepVerify) {
    Write-Host "  [DEEP] Reading source files for content verification..." -ForegroundColor DarkGray
    $snippetBudget = 80000  # chars budget for code snippets
    $snippetUsed = 0

    # Prioritize non-stub, larger files
    $priorityFiles = $fileSummary | Where-Object { -not $_.is_stub -and $_.lines -gt 10 } |
        Sort-Object -Property lines -Descending

    foreach ($pf in $priorityFiles) {
        if ($snippetUsed -ge $snippetBudget) { break }
        $fullPath = Join-Path $RepoRoot $pf.path
        $content = Get-Content $fullPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($content) {
            # Truncate individual files at 3K chars
            if ($content.Length -gt 3000) {
                $content = $content.Substring(0, 3000) + "`n// ... [TRUNCATED at 3K chars, $($pf.lines) lines total]"
            }
            $codeSnippets += "`n--- FILE: $($pf.path) ---`n$content`n"
            $snippetUsed += $content.Length
        }
    }
    Write-Host "  [DEEP] Loaded $([math]::Round($snippetUsed / 1024))KB of source code" -ForegroundColor DarkGray
}

# Build requirements JSON for the prompt (compact)
$reqsJson = $matrix.requirements | ForEach-Object {
    @{ id = $_.id; text = $_.text; category = $_.category; acceptance_criteria = $_.acceptance_criteria }
} | ConvertTo-Json -Depth 5 -Compress

$verifyPrompt = @"
You are verifying an EXISTING codebase against extracted requirements.

## Task
For each requirement, determine its satisfaction status by examining the file inventory$(if ($DeepVerify) { " and actual source code" }).

## Status Rules
- **satisfied**: Code fully implements the requirement (all acceptance criteria met)
- **partial**: Code partially implements it (file exists but incomplete, or some criteria met)
- **not_started**: No evidence of implementation in the codebase

## File Inventory
$fileListCompact

$(if ($DeepVerify -and $codeSnippets) { "## Source Code (key files)`n$codeSnippets" })

## Requirements to Verify
$reqsJson

## Output Format (JSON only)
Return the COMPLETE requirements array with updated statuses and target_files:
{
  "requirements": [
    {
      "id": "REQ-001",
      "status": "satisfied|partial|not_started",
      "target_files": ["path/to/file.cs"],
      "verification_notes": "Brief reason for status"
    }
  ],
  "summary": {
    "satisfied": 0,
    "partial": 0,
    "not_started": 0,
    "total": 0
  }
}
"@

Write-Host "  Calling Sonnet for satisfaction verification..." -ForegroundColor Cyan
$verifyResult = Invoke-SonnetApi -Prompt $verifyPrompt -MaxTokens 32000 `
    -CacheBlocks $cacheBlocks -SystemPrompt "Verify requirements against existing code. Return ONLY valid JSON."

if ($verifyResult.Success -and $verifyResult.Content) {
    Add-ApiCallCost -Model "claude-sonnet-4-6" -Usage $verifyResult.Usage -Phase "satisfaction-verify"

    try {
        $verification = $verifyResult.Content | ConvertFrom-Json

        # Merge verification results into the matrix
        foreach ($vReq in $verification.requirements) {
            $matrixReq = $matrix.requirements | Where-Object { $_.id -eq $vReq.id }
            if ($matrixReq) {
                $matrixReq.status = $vReq.status
                if ($vReq.target_files) { $matrixReq.target_files = $vReq.target_files }
                if ($vReq.verification_notes) {
                    $matrixReq | Add-Member -NotePropertyName "verification_notes" -NotePropertyValue $vReq.verification_notes -Force
                }
            }
        }

        # Save updated matrix
        $matrix | ConvertTo-Json -Depth 10 | Set-Content $matrixPath -Encoding UTF8

        # Display results
        $satisfied = ($matrix.requirements | Where-Object { $_.status -eq "satisfied" }).Count
        $partial = ($matrix.requirements | Where-Object { $_.status -eq "partial" }).Count
        $notStarted = ($matrix.requirements | Where-Object { $_.status -eq "not_started" }).Count
        $healthPct = if ($reqCount -gt 0) { [math]::Round(($satisfied / $reqCount) * 100, 1) } else { 0 }

        Write-Host "`n  ========================================" -ForegroundColor Green
        Write-Host "  EXISTING CODEBASE VERIFICATION RESULTS" -ForegroundColor Green
        Write-Host "  ========================================" -ForegroundColor Green
        Write-Host "  Satisfied:   $satisfied / $reqCount" -ForegroundColor Green
        Write-Host "  Partial:     $partial / $reqCount" -ForegroundColor Yellow
        Write-Host "  Not Started: $notStarted / $reqCount" -ForegroundColor $(if ($notStarted -gt 0) { "Red" } else { "Green" })
        Write-Host "  Health:      ${healthPct}%" -ForegroundColor $(if ($healthPct -ge 90) { "Green" } elseif ($healthPct -ge 50) { "Yellow" } else { "Red" })
        Write-Host "  ========================================" -ForegroundColor Green
    }
    catch {
        Write-Host "  [ERR] Failed to parse verification response: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  Continuing with unverified matrix..." -ForegroundColor Yellow
    }
} else {
    Write-Host "  [ERR] Verification API call failed: $($extractResult.Error)" -ForegroundColor Red
    Write-Host "  Continuing with unverified matrix..." -ForegroundColor Yellow
}

# ============================================================
# PHASE 5: HAND OFF TO CONVERGENCE PIPELINE
# Run Start-V3Pipeline in feature_update mode with pre-built matrix
# Spec-gate is skipped since we already validated
# ============================================================

# Re-read final matrix state
$matrix = Get-Content $matrixPath -Raw | ConvertFrom-Json
$satisfied = ($matrix.requirements | Where-Object { $_.status -eq "satisfied" }).Count
$total = $matrix.requirements.Count
$healthPct = if ($total -gt 0) { [math]::Round(($satisfied / $total) * 100, 1) } else { 0 }

# ── Run Figma Requirement Derivation BEFORE convergence check ──
# This adds FIGMA-* requirements (screens, routes, APIs, components) that may be missing from the matrix
$figmaDeriverPath = Join-Path $v3Dir "lib/modules/figma-req-deriver.ps1"
if (Test-Path $figmaDeriverPath) {
    Write-Host "`n--- Figma Requirement Derivation ---" -ForegroundColor Yellow
    try {
        if (-not (Get-Command Invoke-FigmaRequirementDerivation -ErrorAction SilentlyContinue)) {
            . $figmaDeriverPath
        }
        $figmaResult = Invoke-FigmaRequirementDerivation -RepoRoot $RepoRoot -GsdDir $GsdDir -Config $Config
        if ($figmaResult -and $figmaResult.MergedCount -gt 0) {
            Write-Host "  [FIGMA] Derived $($figmaResult.DerivedCount) requirements, merged $($figmaResult.MergedCount) new into matrix" -ForegroundColor Green
            # Re-read matrix after Figma requirements were added
            $matrix = Get-Content $matrixPath -Raw | ConvertFrom-Json
            $satisfied = ($matrix.requirements | Where-Object { $_.status -eq "satisfied" }).Count
            $total = $matrix.requirements.Count
            $healthPct = if ($total -gt 0) { [math]::Round(($satisfied / $total) * 100, 1) } else { 0 }
            Write-Host "  [FIGMA] Updated health: ${healthPct}% ($satisfied/$total)" -ForegroundColor $(if ($healthPct -ge 100) { "Green" } else { "Yellow" })
        } elseif ($figmaResult -and -not $figmaResult.Skipped) {
            Write-Host "  [FIGMA] All Figma requirements already in matrix (0 new)" -ForegroundColor DarkGray
        } else {
            Write-Host "  [FIGMA] No Figma analysis files found — skipped" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "  [WARN] Figma requirement derivation error: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

if ($healthPct -ge 100) {
    Write-Host "`n  [CONVERGED] All requirements satisfied! No pipeline run needed." -ForegroundColor Green
    if (Get-Command Get-TotalCost -ErrorAction SilentlyContinue) {
        Write-Host "  Total cost: `$$(Get-TotalCost)" -ForegroundColor DarkGray
    }
    try { Stop-Transcript -EA SilentlyContinue } catch {}
    exit 0
}

$remaining = $total - $satisfied
Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  HANDING OFF TO CONVERGENCE PIPELINE" -ForegroundColor Cyan
Write-Host "  $remaining requirements need work (${healthPct}% health)" -ForegroundColor DarkGray
Write-Host "  Mode: feature_update (spec-gate skipped)" -ForegroundColor DarkGray
Write-Host "============================================" -ForegroundColor Cyan

try {
    $result = Start-V3Pipeline `
        -RepoRoot $RepoRoot `
        -Mode "feature_update" `
        -Config $Config `
        -AgentMap $AgentMap `
        -NtfyTopic $NtfyTopic `
        -StartIteration $StartIteration

    if ($result.Success) {
        Write-Host "`n  Existing codebase verification + convergence complete!" -ForegroundColor Green
        Write-Host "  Total cost: `$$([math]::Round($result.TotalCost, 2))" -ForegroundColor Green
    }
    else {
        Write-Host "`n  Pipeline stopped: $($result.Error)" -ForegroundColor Yellow
    }
}
catch {
    Write-Host "`n  [FATAL] Pipeline crashed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Stack: $($_.ScriptStackTrace)" -ForegroundColor DarkRed
    $errFile = Join-Path $GsdDir "logs/fatal-crash.log"
    $errDir = Split-Path $errFile -Parent
    if (-not (Test-Path $errDir)) { New-Item -ItemType Directory -Path $errDir -Force | Out-Null }
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') FATAL: $($_.Exception.Message)`n$($_.ScriptStackTrace)" | Add-Content $errFile
}
finally {
    try { Stop-Transcript -EA SilentlyContinue } catch {}
}
