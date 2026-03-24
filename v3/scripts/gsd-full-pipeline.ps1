<#
.SYNOPSIS
    GSD V3 Full Pipeline — Wire-Up → Code Review → Smoke Test → Final Review → Handoff
.DESCRIPTION
    Orchestrates all pipeline phases to take a generated codebase from "code exists"
    to "production-ready dev handoff". Runs each phase in sequence, passing results
    forward, and generates a comprehensive handoff report.

    Phases:
      1. WIRE-UP: Mock data scan, route-role matrix, integration wiring
      2. CODE REVIEW: 3-model review (Claude+Codex+Gemini) + auto-fix
      3. SMOKE TEST: 9-phase integration validation (build, DB, API, auth, etc.)
      4. FINAL REVIEW: Post-smoke-test verification pass
      5. HANDOFF: Generate developer handoff documentation

    Usage:
      pwsh -File gsd-full-pipeline.ps1 -RepoRoot "D:\repos\project"
      pwsh -File gsd-full-pipeline.ps1 -RepoRoot "D:\repos\project" -ConnectionString "Data Source=..."
      pwsh -File gsd-full-pipeline.ps1 -RepoRoot "D:\repos\project" -StartFrom smoketest
.PARAMETER RepoRoot
    Repository root path (mandatory)
.PARAMETER ConnectionString
    SQL Server connection string for DB validation (optional)
.PARAMETER AzureAdConfig
    JSON object with Azure AD configuration (optional)
.PARAMETER TestUsers
    JSON array of test user credentials (optional)
.PARAMETER StartFrom
    Resume from a specific phase: wireup, codereview, smoketest, finalreview, handoff
.PARAMETER MaxCycles
    Maximum review-fix cycles per phase (default: 3)
.PARAMETER MaxReqs
    Maximum requirements per batch (default: 50)
.PARAMETER SkipWireUp
    Skip the wire-up phase
.PARAMETER SkipCodeReview
    Skip the code review phase
.PARAMETER SkipSmokeTest
    Skip the smoke test phase
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [string]$ConnectionString,
    [string]$AzureAdConfig,
    [string]$TestUsers,
    [ValidateSet("wireup","codereview","smoketest","finalreview","handoff")]
    [string]$StartFrom = "wireup",
    [int]$MaxCycles = 3,
    [int]$MaxReqs = 50,
    [switch]$SkipWireUp,
    [switch]$SkipCodeReview,
    [switch]$SkipSmokeTest
)

$ErrorActionPreference = "Continue"

# ============================================================
# RESOLVE PATHS
# ============================================================

$RepoRoot = (Resolve-Path $RepoRoot).Path
$v3Dir = Split-Path $PSScriptRoot -Parent
$ScriptsDir = $PSScriptRoot
$repoName = Split-Path $RepoRoot -Leaf
$GsdDir = Join-Path $RepoRoot ".gsd"

# ============================================================
# LOGGING
# ============================================================

$timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$logDir = Join-Path $env:USERPROFILE ".gsd-global\logs\$repoName"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir "full-pipeline-$timestamp.log"

function Write-PipelineLog {
    param([string]$Message, [string]$Level = "INFO")
    $entry = "$(Get-Date -Format 'HH:mm:ss') [$Level] $Message"
    Add-Content $logFile -Value $entry -Encoding UTF8 -ErrorAction SilentlyContinue
    $color = switch ($Level) {
        "ERROR" { "Red" }; "WARN" { "Yellow" }; "OK" { "Green" }
        "PHASE" { "Cyan" }; default { "White" }
    }
    Write-Host $entry -ForegroundColor $color
}

# ============================================================
# PHASE TRACKING
# ============================================================

$phaseResults = @{}
$startTime = Get-Date
$phases = @("wireup", "codereview", "smoketest", "finalreview", "handoff")
$startIndex = $phases.IndexOf($StartFrom)

function Start-Phase {
    param([string]$Name, [string]$Description)
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-PipelineLog "PHASE: $Name - $Description" -Level PHASE
    Write-Host ("=" * 70) -ForegroundColor Cyan
    return Get-Date
}

function Complete-Phase {
    param([string]$Name, [datetime]$StartedAt, [string]$Status, [string]$Summary)
    $duration = (Get-Date) - $StartedAt
    $phaseResults[$Name] = @{ status = $Status; duration = $duration.TotalMinutes; summary = $Summary }
    $level = if ($Status -eq "PASS") { "OK" } elseif ($Status -eq "WARN") { "WARN" } else { "ERROR" }
    Write-PipelineLog "$Name completed in $([math]::Round($duration.TotalMinutes, 1)) min - $Status : $Summary" -Level $level
}

# ============================================================
# BANNER
# ============================================================

Write-Host ""
Write-Host "================================================================" -ForegroundColor Magenta
Write-Host "  GSD Full Pipeline: $repoName" -ForegroundColor Magenta
Write-Host "  Starting from: $StartFrom" -ForegroundColor Magenta
Write-Host "  Log: $logFile" -ForegroundColor Magenta
Write-Host "================================================================" -ForegroundColor Magenta

Write-PipelineLog "Pipeline started for $repoName"
if ($ConnectionString) { Write-PipelineLog "Database connection configured" }
if ($AzureAdConfig) { Write-PipelineLog "Azure AD configured" }
if ($TestUsers) { Write-PipelineLog "Test users configured" }

# ============================================================
# PHASE 1: WIRE-UP
# ============================================================

if ($startIndex -le 0 -and -not $SkipWireUp) {
    $ps = Start-Phase "WIRE-UP" "Mock data scan, route-role matrix, integration wiring"

    # Mock data scan (local, free)
    $mockDetector = Join-Path $v3Dir "lib\modules\mock-data-detector.ps1"
    if (Test-Path $mockDetector) {
        . $mockDetector
        $mockResults = Invoke-MockDataScan -RepoRoot $RepoRoot
        $mockCount = ($mockResults.patterns.Count + $mockResults.stubs.Count + $mockResults.placeholders.Count)
        Write-PipelineLog "Mock data scan: $mockCount issues found" -Level $(if ($mockCount -gt 0) { "WARN" } else { "OK" })
        $outDir = Join-Path $GsdDir "smoke-test"
        if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
        $mockResults | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $outDir "mock-data-scan.json") -Encoding UTF8
    }

    # Route-role matrix (local, free)
    $routeMatrixMod = Join-Path $v3Dir "lib\modules\route-role-matrix.ps1"
    if (Test-Path $routeMatrixMod) {
        . $routeMatrixMod
        $matrix = Build-RouteRoleMatrix -RepoRoot $RepoRoot
        if ($matrix) {
            $gapCount = ($matrix | Where-Object { $_.guard_type -eq 'none' -or $_.required_roles.Count -eq 0 }).Count
            Write-PipelineLog "Route-role matrix: $($matrix.Count) routes, $gapCount gaps" -Level $(if ($gapCount -gt 0) { "WARN" } else { "OK" })
            Format-RouteRoleMatrix -Matrix $matrix
            Export-RouteRoleMatrix -Matrix $matrix -OutputPath (Join-Path $outDir "route-role-matrix.json")
        }
    }

    # Wire-up code review pass (focused on integration issues)
    Write-PipelineLog "Running wire-up review pass..."
    & pwsh -File (Join-Path $ScriptsDir "gsd-codereview.ps1") -RepoRoot $RepoRoot -MaxCycles 2 -MaxReqs $MaxReqs -FixModel claude -MinSeverityToFix high

    Complete-Phase "WIRE-UP" $ps "DONE" "Mock scan ($mockCount issues) + route matrix ($($matrix.Count) routes)"
}

# ============================================================
# PHASE 2: CODE REVIEW
# ============================================================

if ($startIndex -le 1 -and -not $SkipCodeReview) {
    $ps = Start-Phase "CODE-REVIEW" "3-model review (Claude+Codex+Gemini) with auto-fix"

    & pwsh -File (Join-Path $ScriptsDir "gsd-codereview.ps1") `
        -RepoRoot $RepoRoot -MaxCycles $MaxCycles -MaxReqs $MaxReqs `
        -FixModel claude -Models "claude,codex,gemini"

    $reportFile = Join-Path $GsdDir "code-review\review-report.json"
    if (Test-Path $reportFile) {
        $report = Get-Content $reportFile -Raw | ConvertFrom-Json
        $status = if ($report.final_issues -eq 0) { "PASS" } elseif ($report.final_issues -lt 50) { "WARN" } else { "FAIL" }
        Complete-Phase "CODE-REVIEW" $ps $status "$($report.final_issues) issues remaining"
    } else {
        Complete-Phase "CODE-REVIEW" $ps "WARN" "Report not found"
    }
}

# ============================================================
# PHASE 3: SMOKE TEST
# ============================================================

if ($startIndex -le 2 -and -not $SkipSmokeTest) {
    $ps = Start-Phase "SMOKE-TEST" "9-phase integration validation (cost-optimized)"

    $stScript = Join-Path $ScriptsDir "gsd-smoketest.ps1"
    if (Test-Path $stScript) {
        $stParams = @("-RepoRoot", $RepoRoot, "-MaxCycles", "2", "-FixModel", "claude")
        if ($ConnectionString) { $stParams += @("-ConnectionString", $ConnectionString) }
        if ($TestUsers) { $stParams += @("-TestUsers", $TestUsers) }
        if ($AzureAdConfig) { $stParams += @("-AzureAdConfig", $AzureAdConfig) }

        & pwsh -File $stScript @stParams

        $stReport = Join-Path $GsdDir "smoke-test\smoke-test-report.json"
        if (Test-Path $stReport) {
            $stResults = Get-Content $stReport -Raw | ConvertFrom-Json
            $failCount = ($stResults.phases | Where-Object { $_.status -eq "fail" }).Count
            $warnCount = ($stResults.phases | Where-Object { $_.status -eq "warn" }).Count
            $status = if ($failCount -eq 0 -and $warnCount -eq 0) { "PASS" } elseif ($failCount -eq 0) { "WARN" } else { "FAIL" }
            Complete-Phase "SMOKE-TEST" $ps $status "$failCount failures, $warnCount warnings"
        } else {
            Complete-Phase "SMOKE-TEST" $ps "WARN" "Report not found"
        }
    } else {
        Complete-Phase "SMOKE-TEST" $ps "SKIP" "gsd-smoketest.ps1 not found"
    }
}

# ============================================================
# PHASE 4: FINAL REVIEW
# ============================================================

if ($startIndex -le 3) {
    $ps = Start-Phase "FINAL-REVIEW" "Post-smoke-test verification"

    & pwsh -File (Join-Path $ScriptsDir "gsd-codereview.ps1") `
        -RepoRoot $RepoRoot -MaxCycles 2 -MaxReqs $MaxReqs `
        -FixModel claude -Models "claude,codex,gemini" -MinSeverityToFix low

    $reportFile = Join-Path $GsdDir "code-review\review-report.json"
    if (Test-Path $reportFile) {
        $report = Get-Content $reportFile -Raw | ConvertFrom-Json
        $status = if ($report.final_issues -eq 0) { "PASS" } elseif ($report.final_issues -lt 20) { "WARN" } else { "FAIL" }
        Complete-Phase "FINAL-REVIEW" $ps $status "$($report.final_issues) issues remaining"
    } else {
        Complete-Phase "FINAL-REVIEW" $ps "WARN" "Report not found"
    }
}

# ============================================================
# PHASE 5: HANDOFF
# ============================================================

if ($startIndex -le 4) {
    $ps = Start-Phase "DEV-HANDOFF" "Generate handoff documentation"

    $totalDuration = (Get-Date) - $startTime
    $handoffDoc = "# $repoName - Developer Handoff Report`nGenerated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n`n"
    $handoffDoc += "## Pipeline Summary`n| Phase | Status | Duration | Summary |`n|-------|--------|----------|---------|`n"

    foreach ($key in ($phaseResults.Keys | Sort-Object)) {
        $r = $phaseResults[$key]
        $handoffDoc += "| $key | $($r.status) | $([math]::Round($r.duration, 1)) min | $($r.summary) |`n"
    }

    $handoffDoc += "`n## Total Duration: $([math]::Round($totalDuration.TotalMinutes, 1)) minutes`n`n"
    $handoffDoc += "## Output Files`n"
    $handoffDoc += "- Code Review: .gsd/code-review/review-summary.md`n"
    $handoffDoc += "- Smoke Test: .gsd/smoke-test/smoke-test-summary.md`n"
    $handoffDoc += "- Gap Report: .gsd/smoke-test/gap-report.md`n"
    $handoffDoc += "- Mock Scan: .gsd/smoke-test/mock-data-scan.json`n"
    $handoffDoc += "- Route Matrix: .gsd/smoke-test/route-role-matrix.json`n"
    $handoffDoc += "- Pipeline Log: $logFile`n"

    $handoffPath = Join-Path $RepoRoot "PIPELINE-HANDOFF.md"
    $handoffDoc | Set-Content $handoffPath -Encoding UTF8
    Write-PipelineLog "Handoff written to $handoffPath"

    Complete-Phase "DEV-HANDOFF" $ps "DONE" "Documentation generated"
}

# ============================================================
# FINAL SUMMARY
# ============================================================

$totalDuration = (Get-Date) - $startTime
Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Magenta
Write-Host "  PIPELINE COMPLETE - $repoName" -ForegroundColor Magenta
Write-Host ("=" * 70) -ForegroundColor Magenta
Write-Host ""

foreach ($key in ($phaseResults.Keys | Sort-Object)) {
    $r = $phaseResults[$key]
    $color = switch ($r.status) { "PASS" { "Green" }; "WARN" { "Yellow" }; "FAIL" { "Red" }; default { "Green" } }
    Write-Host "  $key - $($r.status) ($([math]::Round($r.duration, 1)) min) - $($r.summary)" -ForegroundColor $color
}

Write-Host ""
Write-Host "Total: $([math]::Round($totalDuration.TotalMinutes, 1)) minutes" -ForegroundColor Cyan
Write-Host "Log: $logFile" -ForegroundColor Gray
