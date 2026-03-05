<#
.SYNOPSIS
    LOC Tracking - Track lines of code created/modified by AI per iteration.
    Run AFTER patch-gsd-agent-intelligence.ps1.

.DESCRIPTION
    Tracks AI-generated lines of code using git diff stats after each execute
    phase, correlates with API costs to produce cost-per-line metrics.

    Adds:
    1. Update-LocMetrics function to resilience.ps1
       - Captures git diff --numstat after each execute phase commit
       - Filters source files only (excludes .gsd/, node_modules/, etc.)
       - Tracks per-iteration: lines_added, lines_deleted, lines_net, files_changed
       - Cumulative totals across the full pipeline run

    2. Get-LocNotificationText function to resilience.ps1
       - Returns compact LOC string for ntfy notifications
       - Format: "LOC: +250 / -30 net 220 | 12 files"

    3. Config: loc_tracking block in global-config.json

    4. Data saved to .gsd/costs/loc-metrics.json
       - Per-iteration breakdown with file-level detail
       - Cumulative totals
       - Cost-per-line calculations (cross-referenced with cost-summary.json)

.INSTALL_ORDER
    1-30. (existing scripts)
    31. patch-gsd-loc-tracking.ps1  <- this file
#>

param([string]$UserHome = $env:USERPROFILE)
$ErrorActionPreference = "Stop"

$GsdGlobalDir = Join-Path $UserHome ".gsd-global"

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  GSD LOC Tracking (Lines of Code Metrics)" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

# ── 1. Add loc_tracking config ──

$configPath = Join-Path $GsdGlobalDir "config\global-config.json"
if (Test-Path $configPath) {
    $config = Get-Content $configPath -Raw | ConvertFrom-Json

    if (-not $config.loc_tracking) {
        $config | Add-Member -NotePropertyName "loc_tracking" -NotePropertyValue ([PSCustomObject]@{
            enabled             = $true
            include_extensions  = @(".cs", ".ts", ".tsx", ".js", ".jsx", ".css", ".scss", ".html", ".sql", ".json", ".md", ".ps1", ".py", ".yaml", ".yml")
            exclude_paths       = @(".gsd/", "node_modules/", "bin/", "obj/", "dist/", "build/", ".vs/", ".idea/", "*.min.*", "*.bundle.*", "package-lock.json", "yarn.lock")
            track_per_file      = $true
            cost_per_line       = $true
        })
        $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath -Encoding UTF8
        Write-Host "  [OK] Added loc_tracking config" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] loc_tracking already exists" -ForegroundColor DarkGray
    }
}

# ── 2. Add LOC tracking functions to resilience.ps1 ──

$resilienceFile = Join-Path $GsdGlobalDir "lib\modules\resilience.ps1"
if (Test-Path $resilienceFile) {
    $existing = Get-Content $resilienceFile -Raw

    if ($existing -notlike "*function Update-LocMetrics*") {

        $locFunctions = @'

# ===========================================
# LOC TRACKING (LINES OF CODE METRICS)
# ===========================================

function Update-LocMetrics {
    <#
    .SYNOPSIS
        Captures git diff stats after an execute phase commit and updates
        loc-metrics.json with per-iteration and cumulative LOC data.
        Cross-references cost-summary.json to compute cost-per-line.
    #>
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [string]$GlobalDir,
        [int]$Iteration,
        [string]$Pipeline = "convergence"
    )

    # Check config
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            if (-not $config.loc_tracking -or -not $config.loc_tracking.enabled) { return $null }
        } catch { return $null }
    } else { return $null }

    $excludePaths = @($config.loc_tracking.exclude_paths)
    $includeExts = @($config.loc_tracking.include_extensions)
    $trackPerFile = if ($config.loc_tracking.track_per_file) { $true } else { $false }
    $calcCostPerLine = if ($config.loc_tracking.cost_per_line) { $true } else { $false }

    # Get git diff stats for the last commit (execute phase output)
    $numstat = @()
    try {
        Push-Location $RepoRoot
        $numstat = @(git diff --numstat HEAD~1 HEAD 2>$null)
        Pop-Location
    } catch {
        Pop-Location
        return $null
    }

    if ($numstat.Count -eq 0) {
        Write-Host "  [LOC] No changes detected in last commit" -ForegroundColor DarkGray
        return $null
    }

    # Parse numstat output: "added<tab>deleted<tab>filename"
    $totalAdded = 0
    $totalDeleted = 0
    $filesChanged = 0
    $fileDetails = @()

    foreach ($line in $numstat) {
        if (-not $line -or $line -eq "") { continue }
        $parts = $line -split "\t"
        if ($parts.Count -lt 3) { continue }

        # Binary files show "-" for added/deleted
        if ($parts[0] -eq "-" -or $parts[1] -eq "-") { continue }

        $added = [int]$parts[0]
        $deleted = [int]$parts[1]
        $filePath = $parts[2]

        # Apply exclusion filters
        $excluded = $false
        foreach ($excl in $excludePaths) {
            $exclPattern = $excl -replace '\*', '.*' -replace '/', '[/\\]'
            if ($filePath -match $exclPattern) { $excluded = $true; break }
        }
        if ($excluded) { continue }

        # Apply inclusion filter (by extension)
        if ($includeExts.Count -gt 0) {
            $ext = [System.IO.Path]::GetExtension($filePath)
            if ($ext -and $ext -notin $includeExts) { continue }
        }

        $totalAdded += $added
        $totalDeleted += $deleted
        $filesChanged++

        if ($trackPerFile) {
            $fileDetails += @{
                file    = $filePath
                added   = $added
                deleted = $deleted
                net     = $added - $deleted
            }
        }
    }

    $netLines = $totalAdded - $totalDeleted

    Write-Host "  [LOC] Iteration $Iteration: +$totalAdded / -$totalDeleted (net $netLines) | $filesChanged files" -ForegroundColor Cyan

    # Load or create metrics file
    $costsDir = Join-Path $GsdDir "costs"
    if (-not (Test-Path $costsDir)) {
        New-Item -Path $costsDir -ItemType Directory -Force | Out-Null
    }
    $metricsPath = Join-Path $costsDir "loc-metrics.json"

    $metrics = $null
    if (Test-Path $metricsPath) {
        try { $metrics = Get-Content $metricsPath -Raw | ConvertFrom-Json } catch {}
    }
    if (-not $metrics) {
        $metrics = [PSCustomObject]@{
            pipeline           = $Pipeline
            started            = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            cumulative         = [PSCustomObject]@{
                lines_added    = 0
                lines_deleted  = 0
                lines_net      = 0
                files_changed  = 0
                iterations     = 0
            }
            cost_per_line      = [PSCustomObject]@{
                cost_per_added_line = 0
                cost_per_net_line   = 0
                total_cost_usd      = 0
            }
            iterations         = @()
        }
    }

    # Build iteration entry
    $iterEntry = [PSCustomObject]@{
        iteration     = $Iteration
        timestamp     = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        lines_added   = $totalAdded
        lines_deleted = $totalDeleted
        lines_net     = $netLines
        files_changed = $filesChanged
    }

    if ($trackPerFile -and $fileDetails.Count -gt 0) {
        # Sort by most lines added, top 20
        $topFiles = $fileDetails | Sort-Object { $_.added } -Descending | Select-Object -First 20
        $iterEntry | Add-Member -NotePropertyName "top_files" -NotePropertyValue $topFiles
    }

    # Update cumulative
    $metrics.cumulative.lines_added = [int]$metrics.cumulative.lines_added + $totalAdded
    $metrics.cumulative.lines_deleted = [int]$metrics.cumulative.lines_deleted + $totalDeleted
    $metrics.cumulative.lines_net = [int]$metrics.cumulative.lines_net + $netLines
    $metrics.cumulative.files_changed = [int]$metrics.cumulative.files_changed + $filesChanged
    $metrics.cumulative.iterations = [int]$metrics.cumulative.iterations + 1

    # Append iteration
    $iters = @($metrics.iterations) + @($iterEntry)
    $metrics.iterations = $iters

    # Cross-reference with cost-summary.json for cost-per-line
    if ($calcCostPerLine) {
        $costPath = Join-Path $GsdDir "costs\cost-summary.json"
        if (Test-Path $costPath) {
            try {
                $costs = Get-Content $costPath -Raw | ConvertFrom-Json
                $totalCost = [double]$costs.total_cost_usd
                if ($totalCost -gt 0 -and [int]$metrics.cumulative.lines_added -gt 0) {
                    $metrics.cost_per_line.total_cost_usd = [math]::Round($totalCost, 4)
                    $metrics.cost_per_line.cost_per_added_line = [math]::Round($totalCost / [int]$metrics.cumulative.lines_added, 4)
                    if ([int]$metrics.cumulative.lines_net -gt 0) {
                        $metrics.cost_per_line.cost_per_net_line = [math]::Round($totalCost / [int]$metrics.cumulative.lines_net, 4)
                    }
                }
            } catch {}
        }
    }

    $metrics.last_updated = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")

    # Save
    $metrics | ConvertTo-Json -Depth 10 | Set-Content -Path $metricsPath -Encoding UTF8

    return @{
        Added        = $totalAdded
        Deleted      = $totalDeleted
        Net          = $netLines
        Files        = $filesChanged
        CumAdded     = [int]$metrics.cumulative.lines_added
        CumDeleted   = [int]$metrics.cumulative.lines_deleted
        CumNet       = [int]$metrics.cumulative.lines_net
        CostPerLine  = $metrics.cost_per_line.cost_per_added_line
    }
}

function Get-LocNotificationText {
    <#
    .SYNOPSIS
        Reads loc-metrics.json and returns a compact one-line LOC string for ntfy notifications.
        Returns empty string if LOC tracking is not available.
    #>
    param(
        [string]$GsdDir,
        [switch]$Cumulative   # Show cumulative instead of last iteration
    )
    try {
        $metricsPath = Join-Path $GsdDir "costs\loc-metrics.json"
        if (-not (Test-Path $metricsPath)) { return "" }
        $m = Get-Content $metricsPath -Raw | ConvertFrom-Json

        if ($Cumulative) {
            $added = [int]$m.cumulative.lines_added
            $deleted = [int]$m.cumulative.lines_deleted
            $net = [int]$m.cumulative.lines_net
            $files = [int]$m.cumulative.files_changed
            if ($added -eq 0 -and $deleted -eq 0) { return "" }
            $line = "LOC total: +$added / -$deleted net $net | $files files"
            if ($m.cost_per_line -and [double]$m.cost_per_line.cost_per_added_line -gt 0) {
                $cpl = [math]::Round([double]$m.cost_per_line.cost_per_added_line, 4)
                $line += " | `$$cpl/line"
            }
            return $line
        } else {
            $iters = @($m.iterations)
            if ($iters.Count -eq 0) { return "" }
            $last = $iters[$iters.Count - 1]
            $added = [int]$last.lines_added
            $deleted = [int]$last.lines_deleted
            $net = [int]$last.lines_net
            $files = [int]$last.files_changed
            if ($added -eq 0 -and $deleted -eq 0) { return "" }
            return "LOC: +$added / -$deleted net $net | $files files"
        }
    } catch { return "" }
}
'@

        Add-Content -Path $resilienceFile -Value $locFunctions -Encoding UTF8
        Write-Host "  [OK] Added Update-LocMetrics and Get-LocNotificationText to resilience.ps1" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] LOC tracking functions already exist" -ForegroundColor DarkGray
    }
}

# ── 3. Patch pipeline notifications to include LOC metrics ──

Write-Host ""
Write-Host "  Patching pipeline notifications with LOC metrics..." -ForegroundColor Cyan

# ── 3a. Convergence pipeline: add LOC tracking after execute phase ──

$convergencePipeline = Join-Path $GsdGlobalDir "scripts\final-patch-5-convergence-pipeline.ps1"
# Note: The actual pipeline file may be at the repo level -- we patch the installed version
# The LOC call goes into the pipeline, but since we can't know the exact install path,
# we inject it via the per-iteration notification text instead.

# ── 3b. Patch Get-CostNotificationText to also include LOC ──
# This is the cleanest approach: the existing notification infrastructure already
# calls Get-CostNotificationText everywhere. We add a companion function and
# patch the notification points to include LOC.

# Patch convergence pipeline notifications
$convPipeline = Join-Path $GsdGlobalDir "..\..\vscode\gsd-autonomous-dev\gsd-autonomous-dev\scripts\final-patch-5-convergence-pipeline.ps1"
# Use the known repo path
$convPipelinePath = Join-Path (Split-Path (Split-Path $PSScriptRoot)) "scripts\final-patch-5-convergence-pipeline.ps1"

# Since the pipeline scripts are in this repo and get copied during install,
# we patch them in-place here. The installer will pick them up.

# ── Patch convergence pipeline ──

$thisScriptDir = $PSScriptRoot
if (-not $thisScriptDir) { $thisScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
$repoScriptsDir = $thisScriptDir  # scripts/ directory

$convFile = Join-Path $repoScriptsDir "final-patch-5-convergence-pipeline.ps1"
if (Test-Path $convFile) {
    $convContent = Get-Content $convFile -Raw

    # Add LOC tracking call after execute phase completes (before iteration notification)
    if ($convContent -notlike "*Update-LocMetrics*") {
        # Insert LOC tracking + LOC notification text into per-iteration notification
        # Target: the per-iteration notification block
        $iterTarget = '$iterMsg = "$repoName | Health: ${Health}% (+$([math]::Round($Health - $PrevHealth, 1))%) | Batch: $CurrentBatchSize"'
        if ($convContent -like "*$iterTarget*") {
            $locInjection = @'
$iterMsg = "$repoName | Health: ${Health}% (+$([math]::Round($Health - $PrevHealth, 1))%) | Batch: $CurrentBatchSize"
    # LOC tracking
    if (Get-Command Update-LocMetrics -ErrorAction SilentlyContinue) {
        Update-LocMetrics -RepoRoot $RepoRoot -GsdDir $GsdDir -GlobalDir $GsdGlobalDir -Iteration $Iteration -Pipeline "convergence"
    }
    $locLine = if (Get-Command Get-LocNotificationText -ErrorAction SilentlyContinue) { Get-LocNotificationText -GsdDir $GsdDir } else { "" }
    if ($locLine) { $iterMsg += "`n$locLine" }
'@
            $convContent = $convContent.Replace($iterTarget, $locInjection)
        }

        # Insert cumulative LOC into final completion notifications
        $convTarget = '$convergedMsg = "$repoName | 100% in $Iteration iterations"'
        if ($convContent -like "*$convTarget*") {
            $locFinal = @'
$convergedMsg = "$repoName | 100% in $Iteration iterations"
    $locFinalLine = if (Get-Command Get-LocNotificationText -ErrorAction SilentlyContinue) { Get-LocNotificationText -GsdDir $GsdDir -Cumulative } else { "" }
    if ($locFinalLine) { $convergedMsg += "`n$locFinalLine" }
'@
            $convContent = $convContent.Replace($convTarget, $locFinal)
        }

        # Insert cumulative LOC into stalled notifications
        $stalledTarget = '$stalledMsg = "$repoName | Stuck at ${FinalHealth}% after $Iteration iterations"'
        if ($convContent -like "*$stalledTarget*") {
            $locStalled = @'
$stalledMsg = "$repoName | Stuck at ${FinalHealth}% after $Iteration iterations"
    $locStalledLine = if (Get-Command Get-LocNotificationText -ErrorAction SilentlyContinue) { Get-LocNotificationText -GsdDir $GsdDir -Cumulative } else { "" }
    if ($locStalledLine) { $stalledMsg += "`n$locStalledLine" }
'@
            $convContent = $convContent.Replace($stalledTarget, $locStalled)
        }

        # Insert cumulative LOC into max-iterations notifications
        $maxIterTarget = '$maxIterMsg = "$repoName | ${FinalHealth}% after $Iteration iterations"'
        if ($convContent -like "*$maxIterTarget*") {
            $locMaxIter = @'
$maxIterMsg = "$repoName | ${FinalHealth}% after $Iteration iterations"
    $locMaxLine = if (Get-Command Get-LocNotificationText -ErrorAction SilentlyContinue) { Get-LocNotificationText -GsdDir $GsdDir -Cumulative } else { "" }
    if ($locMaxLine) { $maxIterMsg += "`n$locMaxLine" }
'@
            $convContent = $convContent.Replace($maxIterTarget, $locMaxIter)
        }

        Set-Content -Path $convFile -Value $convContent -Encoding UTF8
        Write-Host "  [OK] Patched convergence pipeline with LOC notifications" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] Convergence pipeline already has LOC tracking" -ForegroundColor DarkGray
    }
} else {
    Write-Host "  [SKIP] Convergence pipeline not found at $convFile" -ForegroundColor DarkGray
}

# ── Patch blueprint pipeline ──

$bpFile = Join-Path $repoScriptsDir "final-patch-4-blueprint-pipeline.ps1"
if (Test-Path $bpFile) {
    $bpContent = Get-Content $bpFile -Raw

    if ($bpContent -notlike "*Update-LocMetrics*") {
        # Per-iteration notification
        $bpIterTarget = '$bpIterMsg = "$repoName | Health: ${Health}% (+$([math]::Round($Health - $PrevHealth, 1))%) | Batch: $CurrentBatchSize"'
        if ($bpContent -like "*$bpIterTarget*") {
            $bpLocIter = @'
$bpIterMsg = "$repoName | Health: ${Health}% (+$([math]::Round($Health - $PrevHealth, 1))%) | Batch: $CurrentBatchSize"
    # LOC tracking
    if (Get-Command Update-LocMetrics -ErrorAction SilentlyContinue) {
        Update-LocMetrics -RepoRoot $RepoRoot -GsdDir $GsdDir -GlobalDir $GsdGlobalDir -Iteration $Iteration -Pipeline "blueprint"
    }
    $bpLocLine = if (Get-Command Get-LocNotificationText -ErrorAction SilentlyContinue) { Get-LocNotificationText -GsdDir $GsdDir } else { "" }
    if ($bpLocLine) { $bpIterMsg += "`n$bpLocLine" }
'@
            $bpContent = $bpContent.Replace($bpIterTarget, $bpLocIter)
        }

        # Final complete notification
        $bpCompleteTarget = '$bpCompleteMsg = "$repoName | 100% in $Iteration iterations"'
        if ($bpContent -like "*$bpCompleteTarget*") {
            $bpLocComplete = @'
$bpCompleteMsg = "$repoName | 100% in $Iteration iterations"
    $bpLocFinalLine = if (Get-Command Get-LocNotificationText -ErrorAction SilentlyContinue) { Get-LocNotificationText -GsdDir $GsdDir -Cumulative } else { "" }
    if ($bpLocFinalLine) { $bpCompleteMsg += "`n$bpLocFinalLine" }
'@
            $bpContent = $bpContent.Replace($bpCompleteTarget, $bpLocComplete)
        }

        # Stalled notification
        $bpStalledTarget = '$bpStalledMsg = "$repoName | Stuck at ${FinalHealth}% after $Iteration iterations"'
        if ($bpContent -like "*$bpStalledTarget*") {
            $bpLocStalled = @'
$bpStalledMsg = "$repoName | Stuck at ${FinalHealth}% after $Iteration iterations"
    $bpLocStalledLine = if (Get-Command Get-LocNotificationText -ErrorAction SilentlyContinue) { Get-LocNotificationText -GsdDir $GsdDir -Cumulative } else { "" }
    if ($bpLocStalledLine) { $bpStalledMsg += "`n$bpLocStalledLine" }
'@
            $bpContent = $bpContent.Replace($bpStalledTarget, $bpLocStalled)
        }

        # Max iterations notification
        $bpMaxTarget = '$bpMaxMsg = "$repoName | ${FinalHealth}% after $Iteration iterations"'
        if ($bpContent -like "*$bpMaxTarget*") {
            $bpLocMax = @'
$bpMaxMsg = "$repoName | ${FinalHealth}% after $Iteration iterations"
    $bpLocMaxLine = if (Get-Command Get-LocNotificationText -ErrorAction SilentlyContinue) { Get-LocNotificationText -GsdDir $GsdDir -Cumulative } else { "" }
    if ($bpLocMaxLine) { $bpMaxMsg += "`n$bpLocMaxLine" }
'@
            $bpContent = $bpContent.Replace($bpMaxTarget, $bpLocMax)
        }

        Set-Content -Path $bpFile -Value $bpContent -Encoding UTF8
        Write-Host "  [OK] Patched blueprint pipeline with LOC notifications" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] Blueprint pipeline already has LOC tracking" -ForegroundColor DarkGray
    }
} else {
    Write-Host "  [SKIP] Blueprint pipeline not found at $bpFile" -ForegroundColor DarkGray
}

# ── 4. Patch heartbeat to include LOC in background notifications ──

$hardeningFile = Join-Path $repoScriptsDir "patch-gsd-hardening.ps1"
if (Test-Path $hardeningFile) {
    $hardContent = Get-Content $hardeningFile -Raw

    if ($hardContent -notlike "*Get-LocNotificationText*") {
        # Patch the Send-HeartbeatIfDue function to include LOC
        $heartbeatTarget = '$costLine = Get-CostNotificationText -GsdDir $GsdDir'
        if ($hardContent -like "*$heartbeatTarget*") {
            $heartbeatLoc = @'
$costLine = Get-CostNotificationText -GsdDir $GsdDir
            $locLine = if (Get-Command Get-LocNotificationText -ErrorAction SilentlyContinue) { Get-LocNotificationText -GsdDir $GsdDir -Cumulative } else { "" }
            if ($locLine) { $msg += "`n$locLine" }
'@
            $hardContent = $hardContent.Replace($heartbeatTarget, $heartbeatLoc)
            Set-Content -Path $hardeningFile -Value $hardContent -Encoding UTF8
            Write-Host "  [OK] Patched heartbeat notifications with LOC" -ForegroundColor Green
        }
    } else {
        Write-Host "  [SKIP] Heartbeat already has LOC" -ForegroundColor DarkGray
    }
} else {
    Write-Host "  [SKIP] Hardening script not found" -ForegroundColor DarkGray
}

# ── 5. Add LOC section to developer-handoff ──

$finalValFile = Join-Path $repoScriptsDir "patch-gsd-final-validation.ps1"
if (Test-Path $finalValFile) {
    $fvContent = Get-Content $finalValFile -Raw

    if ($fvContent -notlike "*LOC METRICS*" -and $fvContent -like "*COST SUMMARY*") {
        # Add LOC section before COST SUMMARY in the handoff
        $costSummaryTarget = '    # ===== COST SUMMARY ====='
        if ($fvContent -like "*$costSummaryTarget*") {
            $locHandoffSection = @'
    # ===== LOC METRICS =====
    $locPath = Join-Path $GsdDir "costs\loc-metrics.json"
    if (Test-Path $locPath) {
        try {
            $locData = Get-Content $locPath -Raw | ConvertFrom-Json
            $handoff += "`n## 11. Lines of Code (AI-Generated)`n"
            $handoff += "| Metric | Value |`n|--------|-------|`n"
            $handoff += "| Lines Added | $($locData.cumulative.lines_added) |`n"
            $handoff += "| Lines Deleted | $($locData.cumulative.lines_deleted) |`n"
            $handoff += "| Net Lines | $($locData.cumulative.lines_net) |`n"
            $handoff += "| Files Changed | $($locData.cumulative.files_changed) |`n"
            $handoff += "| Iterations | $($locData.cumulative.iterations) |`n"
            if ($locData.cost_per_line.cost_per_added_line -gt 0) {
                $handoff += "| Cost per Added Line | `$$($locData.cost_per_line.cost_per_added_line) |`n"
                $handoff += "| Cost per Net Line | `$$($locData.cost_per_line.cost_per_net_line) |`n"
                $handoff += "| Total API Cost | `$$($locData.cost_per_line.total_cost_usd) |`n"
            }
            $handoff += "`n### Per-Iteration Breakdown`n"
            $handoff += "| Iter | Added | Deleted | Net | Files |`n|------|-------|---------|-----|-------|`n"
            foreach ($iter in $locData.iterations) {
                $handoff += "| $($iter.iteration) | +$($iter.lines_added) | -$($iter.lines_deleted) | $($iter.lines_net) | $($iter.files_changed) |`n"
            }
        } catch {}
    }

    # ===== COST SUMMARY =====
'@
            $fvContent = $fvContent.Replace($costSummaryTarget, $locHandoffSection)
            Set-Content -Path $finalValFile -Value $fvContent -Encoding UTF8
            Write-Host "  [OK] Added LOC metrics section to developer-handoff" -ForegroundColor Green
        }
    } else {
        Write-Host "  [SKIP] Developer-handoff already has LOC section or COST SUMMARY not found" -ForegroundColor DarkGray
    }
} else {
    Write-Host "  [SKIP] Final validation script not found" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "  [LOC] Installation complete." -ForegroundColor Green
Write-Host "  Config: global-config.json -> loc_tracking" -ForegroundColor DarkGray
Write-Host "  Functions: Update-LocMetrics, Get-LocNotificationText" -ForegroundColor DarkGray
Write-Host "  Output: .gsd/costs/loc-metrics.json" -ForegroundColor DarkGray
Write-Host "  Notifications: LOC added to per-iteration, completion, stalled, max-iter ntfy messages" -ForegroundColor DarkGray
Write-Host "  Handoff: LOC metrics section added to developer-handoff.md" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Sample ntfy notification:" -ForegroundColor DarkGray
Write-Host "    Iter 3 Complete" -ForegroundColor White
Write-Host "    my-project | Health: 65% (+12%) | Batch: 5" -ForegroundColor White
Write-Host "    Cost: $0.45 run / $1.23 total | 89K tok" -ForegroundColor White
Write-Host "    LOC: +250 / -30 net 220 | 12 files" -ForegroundColor White
Write-Host ""
