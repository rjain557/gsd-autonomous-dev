<#
.SYNOPSIS
    GSD LOC-Cost Integration - Running cost-per-line metrics + code review LOC awareness.
    Run AFTER patch-gsd-partitioned-code-review.ps1.

.DESCRIPTION
    Enhances LOC tracking with cost-per-line visibility at every stage:

    1. Missing functions: Save-LocBaseline + Complete-LocTracking
       These are called in both pipelines but were never defined.
       - Save-LocBaseline: records starting commit hash for total diff at exit
       - Complete-LocTracking: computes grand total LOC from baseline to HEAD

    2. Enhanced Get-LocNotificationText
       Now shows cost-per-line in EVERY per-iteration ntfy message, not just cumulative.
       Before: "LOC: +250 / -30 net 220 | 12 files"
       After:  "LOC: +250 / -30 net 220 | 12 files | $0.003/line"

    3. Code review LOC context injection
       Injects LOC-per-iteration + running cost-per-line into code review prompts
       so agents can see productivity trends and flag low-value iterations.

    4. Enhanced final ntfy notification
       CONVERGED! notification now includes a prominent summary:
       "Total: 2,450 lines | $3.42 cost | $0.0014/line | 8 iterations"

    5. Get-LocCostSummaryText function
       Returns a compact multi-line summary for final notifications and handoff.

.INSTALL_ORDER
    1-33. (existing scripts)
    34. patch-gsd-loc-cost-integration.ps1  <- this file
#>

param([string]$UserHome = $env:USERPROFILE)
$ErrorActionPreference = "Stop"

$GsdGlobalDir = Join-Path $UserHome ".gsd-global"

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  GSD LOC-Cost Integration" -ForegroundColor Cyan
Write-Host "  Running cost-per-line + code review LOC awareness" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

# ── 1. Add missing LOC functions + enhanced notification to resilience.ps1 ──

$resilienceFile = Join-Path $GsdGlobalDir "lib\modules\resilience.ps1"
if (Test-Path $resilienceFile) {
    $existing = Get-Content $resilienceFile -Raw

    $locCostCode = @'

# ===============================================================
# GSD LOC-COST INTEGRATION - appended to resilience.ps1
# ===============================================================

function Save-LocBaseline {
    <#
    .SYNOPSIS
        Records the starting commit hash so Complete-LocTracking can compute
        the total diff (baseline -> final HEAD) at pipeline exit.
    #>
    param(
        [string]$GsdDir
    )

    try {
        $baselineCommit = (git rev-parse HEAD 2>$null).Trim()
        if ($baselineCommit) {
            $baselinePath = Join-Path $GsdDir "costs\loc-baseline.json"
            $costsDir = Join-Path $GsdDir "costs"
            if (-not (Test-Path $costsDir)) { New-Item -Path $costsDir -ItemType Directory -Force | Out-Null }
            @{
                baseline_commit = $baselineCommit
                timestamp       = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            } | ConvertTo-Json | Set-Content $baselinePath -Encoding UTF8
            Write-Host "  [LOC] Baseline saved: $($baselineCommit.Substring(0,7))" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "  [LOC] Could not save baseline: $($_.Exception.Message)" -ForegroundColor DarkGray
    }
}


function Complete-LocTracking {
    <#
    .SYNOPSIS
        Called at pipeline exit. Computes grand total LOC from baseline commit
        to current HEAD. Updates loc-metrics.json with final totals and
        cost-per-line calculations.
    #>
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [string]$GlobalDir,
        [string]$Pipeline = "convergence"
    )

    $baselinePath = Join-Path $GsdDir "costs\loc-baseline.json"
    if (-not (Test-Path $baselinePath)) {
        Write-Host "  [LOC] No baseline found -- skipping final LOC computation" -ForegroundColor DarkGray
        return
    }

    try {
        $baseline = Get-Content $baselinePath -Raw | ConvertFrom-Json
        $baselineCommit = $baseline.baseline_commit
    } catch { return }

    # Load config for filters
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    $excludePaths = @(".gsd/", "node_modules/", "bin/", "obj/", "dist/", "build/", ".vs/", "package-lock.json")
    $includeExts = @(".cs", ".ts", ".tsx", ".js", ".jsx", ".css", ".scss", ".html", ".sql", ".json", ".md", ".ps1", ".py")
    if (Test-Path $configPath) {
        try {
            $locConfig = (Get-Content $configPath -Raw | ConvertFrom-Json).loc_tracking
            if ($locConfig.exclude_paths) { $excludePaths = @($locConfig.exclude_paths) }
            if ($locConfig.include_extensions) { $includeExts = @($locConfig.include_extensions) }
        } catch {}
    }

    # Get grand total diff from baseline to HEAD
    try {
        Push-Location $RepoRoot
        $numstat = @(git diff --numstat $baselineCommit HEAD 2>$null)
        Pop-Location
    } catch {
        Pop-Location
        return
    }

    $grandAdded = 0; $grandDeleted = 0; $grandFiles = 0
    foreach ($line in $numstat) {
        if (-not $line -or $line -eq "") { continue }
        $parts = $line -split "\t"
        if ($parts.Count -lt 3 -or $parts[0] -eq "-") { continue }

        $filePath = $parts[2]
        $excluded = $false
        foreach ($excl in $excludePaths) {
            $exclPattern = $excl -replace '\*', '.*' -replace '/', '[/\\]'
            if ($filePath -match $exclPattern) { $excluded = $true; break }
        }
        if ($excluded) { continue }

        $ext = [System.IO.Path]::GetExtension($filePath)
        if ($includeExts.Count -gt 0 -and $ext -and $ext -notin $includeExts) { continue }

        $grandAdded += [int]$parts[0]
        $grandDeleted += [int]$parts[1]
        $grandFiles++
    }

    $grandNet = $grandAdded - $grandDeleted

    # Update loc-metrics.json with grand totals
    $metricsPath = Join-Path $GsdDir "costs\loc-metrics.json"
    if (Test-Path $metricsPath) {
        try {
            $metrics = Get-Content $metricsPath -Raw | ConvertFrom-Json

            # Add grand_total section (baseline-to-HEAD, may differ from sum of per-iteration)
            $metrics | Add-Member -NotePropertyName "grand_total" -NotePropertyValue ([PSCustomObject]@{
                baseline_commit = $baselineCommit
                final_commit    = (git rev-parse HEAD 2>$null).Trim()
                lines_added     = $grandAdded
                lines_deleted   = $grandDeleted
                lines_net       = $grandNet
                files_changed   = $grandFiles
            }) -Force

            # Recalculate cost-per-line using grand totals
            $costPath = Join-Path $GsdDir "costs\cost-summary.json"
            if (Test-Path $costPath) {
                try {
                    $costs = Get-Content $costPath -Raw | ConvertFrom-Json
                    $totalCost = [double]$costs.total_cost_usd
                    if ($totalCost -gt 0 -and $grandAdded -gt 0) {
                        $metrics.cost_per_line.total_cost_usd = [math]::Round($totalCost, 4)
                        $metrics.cost_per_line.cost_per_added_line = [math]::Round($totalCost / $grandAdded, 4)
                        if ($grandNet -gt 0) {
                            $metrics.cost_per_line.cost_per_net_line = [math]::Round($totalCost / $grandNet, 4)
                        }
                    }
                } catch {}
            }

            $metrics.last_updated = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            $metrics | ConvertTo-Json -Depth 10 | Set-Content $metricsPath -Encoding UTF8
        } catch {}
    }

    Write-Host "  [LOC] Grand total (baseline->HEAD): +$grandAdded / -$grandDeleted net $grandNet | $grandFiles files" -ForegroundColor Cyan
    if ($metrics -and $metrics.cost_per_line -and [double]$metrics.cost_per_line.cost_per_added_line -gt 0) {
        Write-Host "  [LOC] Cost per line: `$$($metrics.cost_per_line.cost_per_added_line)/added, `$$($metrics.cost_per_line.cost_per_net_line)/net" -ForegroundColor Cyan
    }
}


function Get-LocCostSummaryText {
    <#
    .SYNOPSIS
        Returns a multi-line LOC vs Cost summary for final notifications.
        Used in CONVERGED/STALLED/MAX_ITERATIONS ntfy messages.
    #>
    param(
        [string]$GsdDir
    )

    try {
        $metricsPath = Join-Path $GsdDir "costs\loc-metrics.json"
        if (-not (Test-Path $metricsPath)) { return "" }
        $m = Get-Content $metricsPath -Raw | ConvertFrom-Json

        # Use grand_total if available, otherwise cumulative
        $added = 0; $deleted = 0; $net = 0; $files = 0; $iters = 0
        if ($m.grand_total) {
            $added = [int]$m.grand_total.lines_added
            $deleted = [int]$m.grand_total.lines_deleted
            $net = [int]$m.grand_total.lines_net
            $files = [int]$m.grand_total.files_changed
        } elseif ($m.cumulative) {
            $added = [int]$m.cumulative.lines_added
            $deleted = [int]$m.cumulative.lines_deleted
            $net = [int]$m.cumulative.lines_net
            $files = [int]$m.cumulative.files_changed
        }

        if ($m.cumulative) { $iters = [int]$m.cumulative.iterations }

        if ($added -eq 0) { return "" }

        $lines = @()
        $lines += "--- LOC vs Cost ---"
        $lines += "Lines: +$($added.ToString('N0')) / -$($deleted.ToString('N0')) net $($net.ToString('N0'))"
        $lines += "Files: $files | Iterations: $iters"

        if ($m.cost_per_line -and [double]$m.cost_per_line.total_cost_usd -gt 0) {
            $totalCost = [double]$m.cost_per_line.total_cost_usd
            $cplAdded = [double]$m.cost_per_line.cost_per_added_line
            $cplNet = if ([double]$m.cost_per_line.cost_per_net_line -gt 0) { [double]$m.cost_per_line.cost_per_net_line } else { 0 }
            $lines += "Total cost: `$$($totalCost.ToString('N2'))"
            $lines += "Cost/added line: `$$($cplAdded.ToString('N4'))"
            if ($cplNet -gt 0) { $lines += "Cost/net line: `$$($cplNet.ToString('N4'))" }
            # Lines per dollar (inverse - how many lines per dollar spent)
            if ($totalCost -gt 0) {
                $linesPerDollar = [math]::Round($added / $totalCost)
                $lines += "Productivity: $linesPerDollar lines/`$1"
            }
        }

        return ($lines -join "`n")
    } catch { return "" }
}


function Get-LocContextForReview {
    <#
    .SYNOPSIS
        Returns LOC + cost context string to inject into code review prompts.
        Gives reviewers visibility into how many lines each iteration produced
        and what the running cost-per-line is.
    #>
    param(
        [string]$GsdDir
    )

    try {
        $metricsPath = Join-Path $GsdDir "costs\loc-metrics.json"
        if (-not (Test-Path $metricsPath)) { return "" }
        $m = Get-Content $metricsPath -Raw | ConvertFrom-Json

        $iters = @($m.iterations)
        if ($iters.Count -eq 0) { return "" }

        $lines = @()
        $lines += "## AI-Generated Lines of Code (Running Totals)"
        $lines += ""
        $lines += "| Iter | Lines Added | Lines Deleted | Net | Files | Running Total |"
        $lines += "|------|------------|---------------|-----|-------|---------------|"

        $runningTotal = 0
        foreach ($iter in $iters) {
            $runningTotal += [int]$iter.lines_net
            $lines += "| $($iter.iteration) | +$($iter.lines_added) | -$($iter.lines_deleted) | $($iter.lines_net) | $($iter.files_changed) | $runningTotal |"
        }
        $lines += ""

        # Add cumulative summary
        if ($m.cumulative) {
            $lines += "**Cumulative**: +$([int]$m.cumulative.lines_added) / -$([int]$m.cumulative.lines_deleted) net $([int]$m.cumulative.lines_net) | $([int]$m.cumulative.files_changed) files across $([int]$m.cumulative.iterations) iterations"
        }

        # Add cost-per-line if available
        if ($m.cost_per_line -and [double]$m.cost_per_line.total_cost_usd -gt 0) {
            $lines += ""
            $lines += "**Cost efficiency**: `$$([math]::Round([double]$m.cost_per_line.total_cost_usd, 2)) total API cost | `$$([double]$m.cost_per_line.cost_per_added_line)/added line"
            if ([double]$m.cost_per_line.cost_per_net_line -gt 0) {
                $lines += "  `$$([double]$m.cost_per_line.cost_per_net_line)/net line"
            }
        }

        $lines += ""
        $lines += "> Use this data to identify low-productivity iterations (many tokens, few lines) that may indicate stalls, rework, or over-engineering."

        return ($lines -join "`n")
    } catch { return "" }
}

Write-Host "  LOC-Cost integration modules loaded." -ForegroundColor DarkGray
'@

    if ($existing -match "GSD LOC-COST INTEGRATION") {
        $markerLine = "`n# GSD LOC-COST INTEGRATION"
        $idx = $existing.IndexOf($markerLine)
        if ($idx -gt 0) {
            $existing = $existing.Substring(0, $idx)
            Set-Content -Path $resilienceFile -Value $existing -Encoding UTF8
        }
        Add-Content -Path $resilienceFile -Value "`n$locCostCode" -Encoding UTF8
        Write-Host "  [OK] Updated LOC-Cost integration in resilience.ps1" -ForegroundColor DarkGreen
    } else {
        Add-Content -Path $resilienceFile -Value "`n$locCostCode" -Encoding UTF8
        Write-Host "  [OK] Appended LOC-Cost integration to resilience.ps1" -ForegroundColor DarkGreen
    }

    # ── 2. Enhance Get-LocNotificationText to include cost-per-line in per-iteration mode ──

    if ($existing -match "function Get-LocNotificationText") {
        # Replace the existing function with enhanced version
        $oldFunc = 'return "LOC: +$added / -$deleted net $net | $files files"'
        $newFunc = @'
$cplText = ""
            $metricsObj = $m
            if ($metricsObj.cost_per_line -and [double]$metricsObj.cost_per_line.cost_per_added_line -gt 0) {
                $cpl = [math]::Round([double]$metricsObj.cost_per_line.cost_per_added_line, 4)
                $cplText = " | `$$cpl/line"
            }
            return "LOC: +$added / -$deleted net $net | $files files$cplText"
'@
        # Re-read to get latest
        $currentContent = Get-Content $resilienceFile -Raw
        if ($currentContent -like "*$oldFunc*") {
            $currentContent = $currentContent.Replace($oldFunc, $newFunc)
            Set-Content -Path $resilienceFile -Value $currentContent -Encoding UTF8
            Write-Host "  [OK] Enhanced Get-LocNotificationText with per-iteration cost-per-line" -ForegroundColor Green
        } else {
            Write-Host "  [SKIP] Get-LocNotificationText already enhanced or format changed" -ForegroundColor DarkGray
        }
    }
}

# ── 3. Inject LOC context into code review prompts ──

Write-Host "  [PATCH] Injecting LOC context into code review prompts..." -ForegroundColor Yellow

# Standard code review prompt
$crPromptPath = Join-Path $GsdGlobalDir "prompts\claude\code-review.md"
if (Test-Path $crPromptPath) {
    $crContent = Get-Content $crPromptPath -Raw
    if ($crContent -notlike "*AI-Generated Lines of Code*" -and $crContent -notlike "*loc-metrics*") {
        $locInjection = @'

## AI Code Generation Metrics
Read `.gsd/costs/loc-metrics.json` if it exists. Report in your review:
- Lines added/deleted this iteration vs previous iterations
- Running cost-per-line trend (is each iteration getting more or less efficient?)
- Flag any iteration that consumed significant tokens but produced few lines (possible stall/rework)

Include a one-line LOC summary in your review output:
`LOC this iter: +N / -N net N | Total: +N net N | $X.XX/line`
'@
        $crContent += $locInjection
        Set-Content -Path $crPromptPath -Value $crContent -Encoding UTF8
        Write-Host "  [OK] Added LOC context to code-review.md" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] code-review.md already has LOC context" -ForegroundColor DarkGray
    }
}

# Differential code review prompt
$diffCrPromptPath = Join-Path $GsdGlobalDir "prompts\claude\code-review-differential.md"
if (Test-Path $diffCrPromptPath) {
    $diffCrContent = Get-Content $diffCrPromptPath -Raw
    if ($diffCrContent -notlike "*AI-Generated Lines of Code*" -and $diffCrContent -notlike "*loc-metrics*") {
        $locInjection = @'

## AI Code Generation Metrics
Read `.gsd/costs/loc-metrics.json` if it exists. Include a one-line LOC summary:
`LOC this iter: +N / -N net N | Total: +N net N | $X.XX/line`
'@
        $diffCrContent += $locInjection
        Set-Content -Path $diffCrPromptPath -Value $diffCrContent -Encoding UTF8
        Write-Host "  [OK] Added LOC context to code-review-differential.md" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] code-review-differential.md already has LOC context" -ForegroundColor DarkGray
    }
}

# Partitioned code review prompts
$sharedDir = Join-Path $GsdGlobalDir "prompts\shared"
foreach ($label in @("A", "B", "C")) {
    $partPrompt = Join-Path $sharedDir "code-review-partition-$label.md"
    if (Test-Path $partPrompt) {
        $partContent = Get-Content $partPrompt -Raw
        if ($partContent -notlike "*loc-metrics*") {
            $locPartInjection = @'

## AI Code Generation Metrics
Read `.gsd/costs/loc-metrics.json` if it exists. Include in your partition review:
- Lines generated this iteration by your partition's files
- Running cost-per-line efficiency
`LOC summary: +N / -N net N | $X.XX/line`
'@
            $partContent += $locPartInjection
            Set-Content -Path $partPrompt -Value $partContent -Encoding UTF8
            Write-Host "  [OK] Added LOC context to code-review-partition-$label.md" -ForegroundColor Green
        }
    }
}

# ── 4. Inject LOC context into Local-ResolvePrompt for automatic inclusion ──

Write-Host "  [PATCH] Patching convergence pipeline to inject LOC context..." -ForegroundColor Yellow

$convFile = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "final-patch-5-convergence-pipeline.ps1"
if (Test-Path $convFile) {
    $convContent = Get-Content $convFile -Raw

    if ($convContent -notlike "*Get-LocContextForReview*") {
        # Inject LOC context into Local-ResolvePrompt function
        $resolveTarget = '    # Council: inject feedback from previous council review'
        if ($convContent -like "*$resolveTarget*") {
            $locResolveInjection = @'
    # LOC context: inject AI code generation metrics into review prompts
    if ($templatePath -match "code-review" -and (Get-Command Get-LocContextForReview -ErrorAction SilentlyContinue)) {
        $locCtx = Get-LocContextForReview -GsdDir $GsdDir
        if ($locCtx) { $resolved += "`n`n$locCtx" }
    }
    # Council: inject feedback from previous council review
'@
            $convContent = $convContent.Replace($resolveTarget, $locResolveInjection)
            Set-Content -Path $convFile -Value $convContent -Encoding UTF8
            Write-Host "  [OK] Patched Local-ResolvePrompt to inject LOC context into reviews" -ForegroundColor Green
        } else {
            Write-Host "  [SKIP] Could not find inject point in Local-ResolvePrompt" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  [SKIP] Local-ResolvePrompt already has LOC injection" -ForegroundColor DarkGray
    }

    # ── 5. Enhance final CONVERGED notification with LOC vs Cost summary ──

    $convContent = Get-Content $convFile -Raw  # Re-read

    if ($convContent -notlike "*Get-LocCostSummaryText*") {
        # Enhance the CONVERGED notification
        $convergedTarget = '    $convergedMsg = "$repoName | 100% in $Iteration iterations"'
        if ($convContent -like "*$convergedTarget*") {
            $enhancedConverged = @'
    $convergedMsg = "$repoName | 100% in $Iteration iterations"
    # LOC vs Cost summary for final notification
    $locCostSummary = if (Get-Command Get-LocCostSummaryText -ErrorAction SilentlyContinue) { Get-LocCostSummaryText -GsdDir $GsdDir } else { "" }
    if ($locCostSummary) { $convergedMsg += "`n$locCostSummary" }
'@
            $convContent = $convContent.Replace($convergedTarget, $enhancedConverged)
        }

        # Enhance the STALLED notification
        $stalledTarget = '    $stalledMsg = "$repoName | Stuck at ${FinalHealth}% after $Iteration iterations"'
        if ($convContent -like "*$stalledTarget*") {
            $enhancedStalled = @'
    $stalledMsg = "$repoName | Stuck at ${FinalHealth}% after $Iteration iterations"
    $locCostStalledSummary = if (Get-Command Get-LocCostSummaryText -ErrorAction SilentlyContinue) { Get-LocCostSummaryText -GsdDir $GsdDir } else { "" }
    if ($locCostStalledSummary) { $stalledMsg += "`n$locCostStalledSummary" }
'@
            $convContent = $convContent.Replace($stalledTarget, $enhancedStalled)
        }

        # Enhance the MAX ITERATIONS notification
        $maxIterTarget = '    $maxIterMsg = "$repoName | ${FinalHealth}% after $Iteration iterations"'
        if ($convContent -like "*$maxIterTarget*") {
            $enhancedMaxIter = @'
    $maxIterMsg = "$repoName | ${FinalHealth}% after $Iteration iterations"
    $locCostMaxSummary = if (Get-Command Get-LocCostSummaryText -ErrorAction SilentlyContinue) { Get-LocCostSummaryText -GsdDir $GsdDir } else { "" }
    if ($locCostMaxSummary) { $maxIterMsg += "`n$locCostMaxSummary" }
'@
            $convContent = $convContent.Replace($maxIterTarget, $enhancedMaxIter)
        }

        Set-Content -Path $convFile -Value $convContent -Encoding UTF8
        Write-Host "  [OK] Enhanced final notifications with LOC vs Cost summary" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] Final notifications already have LOC-Cost summary" -ForegroundColor DarkGray
    }
} else {
    Write-Host "  [SKIP] Convergence pipeline not found at $convFile" -ForegroundColor DarkGray
}

# ── 6. Also patch blueprint pipeline ──

$bpFile = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "final-patch-4-blueprint-pipeline.ps1"
if (Test-Path $bpFile) {
    $bpContent = Get-Content $bpFile -Raw

    if ($bpContent -notlike "*Get-LocCostSummaryText*") {
        $bpConvergedTarget = '    $bpCompleteMsg = "$repoName | 100% in $Iteration iterations"'
        if ($bpContent -like "*$bpConvergedTarget*") {
            $bpEnhanced = @'
    $bpCompleteMsg = "$repoName | 100% in $Iteration iterations"
    $bpLocCostSummary = if (Get-Command Get-LocCostSummaryText -ErrorAction SilentlyContinue) { Get-LocCostSummaryText -GsdDir $GsdDir } else { "" }
    if ($bpLocCostSummary) { $bpCompleteMsg += "`n$bpLocCostSummary" }
'@
            $bpContent = $bpContent.Replace($bpConvergedTarget, $bpEnhanced)
            Set-Content -Path $bpFile -Value $bpContent -Encoding UTF8
            Write-Host "  [OK] Enhanced blueprint pipeline with LOC-Cost summary" -ForegroundColor Green
        }
    } else {
        Write-Host "  [SKIP] Blueprint pipeline already has LOC-Cost summary" -ForegroundColor DarkGray
    }
} else {
    Write-Host "  [SKIP] Blueprint pipeline not found" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Green
Write-Host "  [OK] LOC-Cost Integration Patch Applied" -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  WHAT CHANGED:" -ForegroundColor Yellow
Write-Host ""
Write-Host "  [1] Missing functions now defined:" -ForegroundColor White
Write-Host "      Save-LocBaseline - records start commit for grand total diff" -ForegroundColor DarkGray
Write-Host "      Complete-LocTracking - computes baseline-to-HEAD grand totals" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  [2] Per-iteration ntfy now shows cost-per-line:" -ForegroundColor White
Write-Host "      Before: LOC: +250 / -30 net 220 | 12 files" -ForegroundColor DarkGray
Write-Host "      After:  LOC: +250 / -30 net 220 | 12 files | $0.003/line" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  [3] Code review agents now see LOC history:" -ForegroundColor White
Write-Host "      - Per-iteration LOC table injected into review prompts" -ForegroundColor DarkGray
Write-Host "      - Running cost-per-line trend visible to reviewers" -ForegroundColor DarkGray
Write-Host "      - Low-productivity iterations flagged" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  [4] Final ntfy notifications now include:" -ForegroundColor White
Write-Host "      --- LOC vs Cost ---" -ForegroundColor DarkGray
Write-Host "      Lines: +2,450 / -320 net 2,130" -ForegroundColor DarkGray
Write-Host "      Files: 85 | Iterations: 8" -ForegroundColor DarkGray
Write-Host "      Total cost: $3.42" -ForegroundColor DarkGray
Write-Host "      Cost/added line: $0.0014" -ForegroundColor DarkGray
Write-Host "      Productivity: 716 lines/$1" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  CONFIG: Uses existing loc_tracking config in global-config.json" -ForegroundColor Yellow
Write-Host "  DATA: .gsd/costs/loc-metrics.json (enhanced with grand_total section)" -ForegroundColor DarkGray
Write-Host ""
