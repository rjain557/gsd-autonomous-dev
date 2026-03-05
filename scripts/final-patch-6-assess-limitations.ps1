<#
.SYNOPSIS
    Final Integration Sub-Patch 6/6: Assess + Limitations + Runner
    Fixes GAP 14: Multi-interface gsd-assess
    Updates KNOWN-LIMITATIONS with final gap closure audit
    Creates master runner script to execute all 7 patches in order
#>
param([string]$UserHome = $env:USERPROFILE)
$ErrorActionPreference = "Stop"
$GsdGlobalDir = Join-Path $UserHome ".gsd-global"
$BlueprintDir = Join-Path $GsdGlobalDir "blueprint"

Write-Host "[CHART] Sub-patch 6/6: Assess + limitations + runner..." -ForegroundColor Yellow

# ========================================
# GAP 14: Multi-interface gsd-assess
# ========================================

$assessScript = @'
<#
.SYNOPSIS
    GSD Assess - Multi-Interface Edition with File Map
#>
param([switch]$DryRun, [switch]$MapOnly)

$RepoRoot = (Get-Location).Path
$UserHome = $env:USERPROFILE
$GlobalDir = Join-Path $UserHome ".gsd-global"
$GsdDir = Join-Path $RepoRoot ".gsd"

. "$GlobalDir\lib\modules\resilience.ps1"
if (Test-Path "$GlobalDir\lib\modules\interfaces.ps1") { . "$GlobalDir\lib\modules\interfaces.ps1" }
if (Test-Path "$GlobalDir\lib\modules\interface-wrapper.ps1") { . "$GlobalDir\lib\modules\interface-wrapper.ps1" }

@($GsdDir, "$GsdDir\assessment", "$GsdDir\logs") | ForEach-Object {
    if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
}

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  GSD Codebase Assessment - Multi-Interface" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan

# Detect and display interfaces
$InterfaceContext = ""
if (Get-Command Initialize-ProjectInterfaces -ErrorAction SilentlyContinue) {
    $ifaceResult = Initialize-ProjectInterfaces -RepoRoot $RepoRoot -GsdDir $GsdDir
    $InterfaceContext = $ifaceResult.Context
    if ($ifaceResult.Interfaces.Count -gt 0 -and (Get-Command Show-InterfaceSummary -ErrorAction SilentlyContinue)) {
        Show-InterfaceSummary -Interfaces $ifaceResult.Interfaces
    } else {
        Write-Host "  [!!]  No design interfaces detected" -ForegroundColor DarkYellow
        Write-Host "  Expected: design\web\v##, design\mcp\v##, etc." -ForegroundColor DarkGray
    }
} else {
    Write-Host "  [!!]  No design interfaces detected" -ForegroundColor DarkYellow
    Write-Host "  Expected: design\web\v##, design\mcp\v##, etc." -ForegroundColor DarkGray
}

# Count source files
$sourceFiles = @(Get-ChildItem -Path $RepoRoot -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object {
        $_.FullName -notmatch '(node_modules|\.git|bin[\\/]|obj[\\/]|packages|dist|build|\.gsd|_analysis|_stubs)' -and
        $_.Extension -match '\.(cs|sql|tsx?|jsx?|css|scss|json|md|html|xml|yaml|yml|csproj|sln)$'
    })

Write-Host "  $($sourceFiles.Count) source files to assess" -ForegroundColor Yellow
$sourceFiles | Group-Object Extension | Sort-Object Count -Descending | Select-Object -First 8 | ForEach-Object {
    Write-Host "     $($_.Name): $($_.Count)" -ForegroundColor DarkGray
}
Write-Host ""

# Generate file map
$fileMapPath = $null
if (Get-Command Update-FileMap -ErrorAction SilentlyContinue) {
    $fileMapPath = Update-FileMap -Root $RepoRoot -GsdPath $GsdDir
    Write-Host ""
}

if ($MapOnly) {
    Write-Host "  [OK] File map updated (MapOnly mode)" -ForegroundColor Green
    Write-Host ""; exit 0
}

# Build prompt
$assessPromptPath = "$GlobalDir\prompts\claude\assess.md"
if (-not (Test-Path $assessPromptPath)) {
    Write-Host "  [XX] assess.md not found." -ForegroundColor Red; exit 1
}

$prompt = (Get-Content $assessPromptPath -Raw).Replace("{{REPO_ROOT}}", $RepoRoot).Replace("{{GSD_DIR}}", $GsdDir).Replace("{{FIGMA_PATH}}", "(see interface context)").Replace("{{FIGMA_VERSION}}", "(multi-interface)").Replace("{{INTERFACE_CONTEXT}}", $InterfaceContext)

if ($fileMapPath) {
    $prompt += "`n`n## File Map`nJSON: $fileMapPath`nTree: $GsdDir\file-map-tree.md`nRead the tree to understand repo structure.`n"
}

if (-not $DryRun) {
    Write-Host "[SEARCH] Running assessment..." -ForegroundColor Cyan
    $startTime = Get-Date
    Invoke-WithRetry -Agent "claude" -Prompt $prompt -Phase "assess" `
        -LogFile "$GsdDir\logs\assessment.log" -CurrentBatchSize 1 -GsdDir $GsdDir | Out-Null

    if (Get-Command Update-FileMap -ErrorAction SilentlyContinue) {
        Write-Host "  Refreshing file map..." -ForegroundColor DarkGray
        $null = Update-FileMap -Root $RepoRoot -GsdPath $GsdDir
    }

    Write-Host "  [TIME]  $([math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)) min" -ForegroundColor DarkGray

    $summaryFile = Join-Path $GsdDir "assessment\assessment-summary.md"
    if (Test-Path $summaryFile) {
        Write-Host ""; Write-Host "=== Summary ===" -ForegroundColor Green
        Get-Content $summaryFile | ForEach-Object { Write-Host "  $_" }
    }

    $classFile = Join-Path $GsdDir "assessment\work-classification.json"
    if (Test-Path $classFile) {
        try {
            $work = Get-Content $classFile -Raw | ConvertFrom-Json
            Write-Host ""; Write-Host "  Work Breakdown:" -ForegroundColor Yellow
            Write-Host "    [OK] Skip:     $($work.summary.skip)" -ForegroundColor Green
            Write-Host "    [!!] Refactor: $($work.summary.refactor)" -ForegroundColor DarkYellow
            Write-Host "    [->] Extend:   $($work.summary.extend)" -ForegroundColor Cyan
            Write-Host "    [++] New:      $($work.summary.build_new)" -ForegroundColor Magenta
        } catch {}
    }

    Write-Host ""
    Write-Host "  Output:" -ForegroundColor DarkGray
    Write-Host "    .gsd\assessment\        Assessment results" -ForegroundColor DarkGray
    Write-Host "    .gsd\file-map.json      Repo inventory" -ForegroundColor DarkGray
    Write-Host "    .gsd\file-map-tree.md   Directory tree" -ForegroundColor DarkGray
} else {
    Write-Host "  [DRY RUN] Would assess $($sourceFiles.Count) files" -ForegroundColor DarkYellow
}
Write-Host ""

'@

$assessDir = Join-Path $BlueprintDir "scripts"
if (-not (Test-Path $assessDir)) { New-Item -ItemType Directory -Path $assessDir -Force | Out-Null }
Set-Content -Path "$assessDir\assess.ps1" -Value $assessScript -Encoding UTF8
Write-Host "   [OK] assess.ps1 (multi-interface)" -ForegroundColor DarkGreen

# ========================================
# Update assess prompt for {{INTERFACE_CONTEXT}}
# ========================================

$assessPromptFile = "$GsdGlobalDir\prompts\claude\assess.md"
if (Test-Path $assessPromptFile) {
    $existing = Get-Content $assessPromptFile -Raw
    if ($existing -notmatch "INTERFACE_CONTEXT") {
        $patch = @"

## Project Interfaces
{{INTERFACE_CONTEXT}}

## Multi-Interface Rules
- Assess EACH interface separately
- For interfaces WITH _analysis/: cross-reference code against deliverables
- Group work-classification by interface + shared backend
- Flag inconsistencies between interfaces
"@
        $updated = $existing.Replace("## STEP 1: Discovery Scan", "$patch`n`n## STEP 1: Discovery Scan")
        Set-Content -Path $assessPromptFile -Value $updated -Encoding UTF8
        Write-Host "   [OK] assess.md prompt updated for interfaces" -ForegroundColor DarkGreen
    }
}

Write-Host ""

# ========================================
# Updated KNOWN-LIMITATIONS
# ========================================

Write-Host "[CLIP] Updating final limitations..." -ForegroundColor Yellow

$limitations = @"
# GSD - Final Gap Audit (All Patches Applied)

## CLOSED GAPS

| # | Issue | Fix | Status |
|---|-------|-----|--------|
| 1 | Token/rate limit exhaustion | Wait-ForQuotaReset: sleep hourly, test, up to 24h | [OK] |
| 2 | Corrupt JSON from agent | Test-JsonFile + .last-good backup restore | [OK] |
| 3 | Code compiles but logically wrong | Storyboard-aware verify traces data paths + state handling | [OK] Improved |
| 4 | Figma binary unreadable | _analysis/ deliverables from Figma Make | [OK] |
| 5 | Spec contradictions waste iterations | Invoke-SpecConsistencyCheck blocks on critical conflicts before loop | [OK] |
| 6 | SQL validation incomplete | Test-SqlFiles + sqlcmd syntax parse when available | [OK] |
| 7 | Agent boundary crossing | Test-AgentBoundaries + auto-revert | [OK] |
| 8 | CLI version changes undetected | Test-CliVersionCompat parses versions, warns on untested | [OK] |
| 9 | Disk check only in retry | Test-DiskSpace at top of every iteration in both loops | [OK] |
| 10 | Network failure | Wait-ForNetwork HTTP HEAD check, 10s x 6 polls (60s max), then skip | [OK] |
| 11 | Blueprint missing interface detection | Loads interface-wrapper, Initialize-ProjectInterfaces | [OK] |
| 12 | Figma Make prompts never selected | Select-BlueprintPrompt / Select-BuildPrompt wired in | [OK] |
| 13 | Convergence not multi-interface aware | Interface context injected into all 5 phase prompts | [OK] |
| 14 | gsd-assess not multi-interface | Rewritten with per-interface scanning + _analysis/ | [OK] |
| 15 | No spec consistency pre-check | Invoke-SpecConsistencyCheck (same as #5) | [OK] |
| 16 | sqlcmd flag set but never used | Test-SqlSyntaxWithSqlcmd wired into Test-SqlFiles | [OK] |

## REMAINING (requires human)

| # | Scenario | Why | Frequency |
|---|----------|-----|-----------|
| A | API key expired | Can't self-renew credentials | Rare |
| B | CLI breaking changes | Can't predict flag renames (but version check warns) | Rare |
| C | Quota exhausted > 24h | Monthly billing cap | Monthly worst case |
| D | Contradictory specs | Spec check catches them but can't resolve - human decides | Per-project |
| E | Runtime logic bugs | Storyboard verify is structural, not runtime. Full fix needs Playwright | Edge cases |

## INSTALL ORDER

``````powershell
# All 7 scripts in order:
powershell -ExecutionPolicy Bypass -File install-gsd-global.ps1
powershell -ExecutionPolicy Bypass -File install-gsd-blueprint.ps1
powershell -ExecutionPolicy Bypass -File patch-gsd-partial-repo.ps1
powershell -ExecutionPolicy Bypass -File patch-gsd-resilience.ps1
powershell -ExecutionPolicy Bypass -File patch-gsd-hardening.ps1
powershell -ExecutionPolicy Bypass -File patch-gsd-figma-make.ps1
# Then the 6 final integration sub-patches:
powershell -ExecutionPolicy Bypass -File final-patch-1-spec-check.ps1
powershell -ExecutionPolicy Bypass -File final-patch-2-sql-cli.ps1
powershell -ExecutionPolicy Bypass -File final-patch-3-storyboard-verify.ps1
powershell -ExecutionPolicy Bypass -File final-patch-4-blueprint-pipeline.ps1
powershell -ExecutionPolicy Bypass -File final-patch-5-convergence-pipeline.ps1
powershell -ExecutionPolicy Bypass -File final-patch-6-assess-limitations.ps1
``````
"@

Set-Content -Path "$GsdGlobalDir\KNOWN-LIMITATIONS.md" -Value $limitations -Encoding UTF8
Write-Host "   [OK] KNOWN-LIMITATIONS.md (final)" -ForegroundColor DarkGreen

Write-Host ""

# ========================================
# Master runner script
# ========================================

Write-Host "[ROCKET] Copying master install script..." -ForegroundColor Yellow

# Copy the actual install-gsd-all.ps1 from the source scripts directory instead of a stale hardcoded version
$sourceInstaller = Join-Path $scriptDir "install-gsd-all.ps1"
if (Test-Path $sourceInstaller) {
    Copy-Item -Path $sourceInstaller -Destination "$GsdGlobalDir\install-gsd-all.ps1" -Force
    Write-Host "   [OK] install-gsd-all.ps1 (copied from source)" -ForegroundColor DarkGreen
} else {
    Write-Host "   [!!] install-gsd-all.ps1 not found in script directory - skipped" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Green
Write-Host "  [OK] Sub-patch 6/6 Complete - All Gaps Addressed" -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green
Write-Host ""
