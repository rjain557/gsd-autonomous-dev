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
# 3b: Show-InterfaceSummary called explicitly by caller
$InterfaceContext = ""
if (Get-Command Initialize-ProjectInterfaces -ErrorAction SilentlyContinue) {
    $ifaceResult = Initialize-ProjectInterfaces -RepoRoot $RepoRoot -GsdDir $GsdDir
    $InterfaceContext = $ifaceResult.Context
    # 7c: Consolidated interface display (no duplication)
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

# 7a: Use -Include parameter to filter at filesystem level (faster than Where-Object)
$sourceExtensions = @("*.cs","*.sql","*.ts","*.tsx","*.js","*.jsx","*.css","*.scss","*.json","*.md","*.html","*.xml","*.yaml","*.yml","*.csproj","*.sln")
$sourceFiles = @(Get-ChildItem -Path $RepoRoot -Recurse -File -Include $sourceExtensions -ErrorAction SilentlyContinue |
    Where-Object {
        $_.FullName -notmatch '(node_modules|\.git|bin[\\/]|obj[\\/]|packages|dist|build|\.gsd|_analysis|_stubs)'
    })

Write-Host "  $($sourceFiles.Count) source files to assess" -ForegroundColor Yellow
$sourceFiles | Group-Object Extension | Sort-Object Count -Descending | Select-Object -First 8 | ForEach-Object {
    Write-Host "     $($_.Name): $($_.Count)" -ForegroundColor DarkGray
}
Write-Host ""

# Generate file map
# 7b: Only generate if not fresh (check freshness)
$fileMapPath = $null
if (Get-Command Update-FileMap -ErrorAction SilentlyContinue) {
    $existingMap = Join-Path $GsdDir "file-map.json"
    $mapIsFresh = (Test-Path $existingMap) -and ((Get-Date) - (Get-Item $existingMap).LastWriteTime).TotalMinutes -lt 5
    if (-not $mapIsFresh) {
        $fileMapPath = Update-FileMap -Root $RepoRoot -GsdPath $GsdDir
        Write-Host ""
    } else {
        $fileMapPath = $existingMap
        Write-Host "  File map is fresh (<5min), skipping regeneration" -ForegroundColor DarkGray
    }
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

    # 7b: Only refresh file map after assessment (not before AND after)
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
