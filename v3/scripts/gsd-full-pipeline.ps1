<#
.SYNOPSIS
    GSD V4 Full Pipeline - 9-phase pipeline from convergence to dev handoff
.DESCRIPTION
    Orchestrates all pipeline phases to take a codebase from requirements convergence
    through build verification, code review, runtime validation, and dev handoff.

    Phases:
      1. CONVERGENCE    - Run convergence loop (skip if already 100% health)
      2. BUILD GATE     - Compile check + auto-fix (dotnet build + npm run build)
      3. WIRE-UP        - Mock data scan, route-role matrix, wire-up fixes
      4. CODE REVIEW    - 3-model review (Claude+Codex+Gemini) + auto-fix
      5. BUILD VERIFY   - Re-run build gate to confirm review fixes compile
      6. RUNTIME        - Start services, test endpoints, validate CRUD
      7. SMOKE TEST     - 9-phase integration validation
      8. FINAL REVIEW   - Post-smoke-test verification (fix all severities)
      9. DEV HANDOFF    - Generate PIPELINE-HANDOFF.md

    Usage:
      pwsh -File gsd-full-pipeline.ps1 -RepoRoot "D:\repos\project"
      pwsh -File gsd-full-pipeline.ps1 -RepoRoot "D:\repos\project" -StartFrom buildgate -SkipConvergence
      pwsh -File gsd-full-pipeline.ps1 -RepoRoot "D:\repos\project" -ConnectionString "Data Source=..."
.PARAMETER RepoRoot
    Repository root path (mandatory)
.PARAMETER ConnectionString
    SQL Server connection string for DB validation (optional)
.PARAMETER AzureAdConfig
    JSON object with Azure AD configuration (optional)
.PARAMETER TestUsers
    JSON array of test user credentials (optional)
.PARAMETER StartFrom
    Resume from a specific phase: convergence, buildgate, wireup, codereview, buildverify, runtime, smoketest, finalreview, handoff
.PARAMETER MaxCycles
    Maximum review-fix cycles per phase (default: 3)
.PARAMETER MaxReqs
    Maximum requirements per batch (default: 50)
.PARAMETER BackendPort
    Port for the backend server (default: 5000)
.PARAMETER FrontendPort
    Port for the frontend dev server (default: 3000)
.PARAMETER SkipConvergence
    Skip the convergence phase
.PARAMETER SkipBuildGate
    Skip the build gate phase
.PARAMETER SkipWireUp
    Skip the wire-up phase
.PARAMETER SkipCodeReview
    Skip the code review phase
.PARAMETER SkipRuntime
    Skip the runtime validation phase
.PARAMETER SkipSmokeTest
    Skip the smoke test phase
.PARAMETER SkipFinalReview
    Skip the final review phase
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [string]$ConnectionString,
    [string]$AzureAdConfig,
    [string]$TestUsers,
    [ValidateSet("convergence","buildgate","wireup","codereview","buildverify","runtime","smoketest","finalreview","handoff")]
    [string]$StartFrom = "convergence",
    [int]$MaxCycles = 3,
    [int]$MaxReqs = 50,
    [int]$BackendPort = 5000,
    [int]$FrontendPort = 3000,
    [switch]$SkipConvergence,
    [switch]$SkipBuildGate,
    [switch]$SkipWireUp,
    [switch]$SkipCodeReview,
    [switch]$SkipRuntime,
    [switch]$SkipSmokeTest,
    [switch]$SkipFinalReview
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
$logDir = Join-Path $env:USERPROFILE ".gsd-global\logs\${repoName}"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir "full-pipeline-${timestamp}.log"

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
$phases = @("convergence", "buildgate", "wireup", "codereview", "buildverify", "runtime", "smoketest", "finalreview", "handoff")
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
    Write-PipelineLog "$Name completed in $([math]::Round($duration.TotalMinutes, 1)) min - ${Status} - $Summary" -Level $level
}

# ============================================================
# BANNER
# ============================================================

Write-Host ""
Write-Host "================================================================" -ForegroundColor Magenta
Write-Host "  GSD V4 Full Pipeline: $repoName" -ForegroundColor Magenta
Write-Host "  Starting from: $StartFrom" -ForegroundColor Magenta
Write-Host "  Log: $logFile" -ForegroundColor Magenta
Write-Host "================================================================" -ForegroundColor Magenta

Write-PipelineLog "Pipeline started for $repoName"
if ($ConnectionString) { Write-PipelineLog "Database connection configured" }
if ($AzureAdConfig) { Write-PipelineLog "Azure AD configured" }
if ($TestUsers) { Write-PipelineLog "Test users configured" }

# ============================================================
# PHASE 1: CONVERGENCE
# ============================================================

if ($startIndex -le 0 -and -not $SkipConvergence) {
    $ps = Start-Phase "CONVERGENCE" "Run convergence loop until 100% health"

    # Check current health score
    $healthFile = Join-Path $GsdDir "health\health-score.json"
    $currentHealth = 0
    if (Test-Path $healthFile) {
        try {
            $healthData = Get-Content $healthFile -Raw | ConvertFrom-Json
            $currentHealth = $healthData.health_percent
        } catch { }
    }

    if ($currentHealth -ge 100) {
        Write-PipelineLog "Health already at ${currentHealth}% - skipping convergence" -Level OK
        Complete-Phase "CONVERGENCE" $ps "SKIP" "Already at ${currentHealth}%"
    } else {
        Write-PipelineLog "Current health: ${currentHealth}% - running convergence pipeline"

        $existingScript = Join-Path $ScriptsDir "gsd-existing.ps1"
        if (Test-Path $existingScript) {
            & pwsh -File $existingScript -RepoRoot $RepoRoot
            # Re-check health
            if (Test-Path $healthFile) {
                try {
                    $healthData = Get-Content $healthFile -Raw | ConvertFrom-Json
                    $currentHealth = $healthData.health_percent
                } catch { }
            }
            $status = if ($currentHealth -ge 100) { "PASS" } elseif ($currentHealth -ge 80) { "WARN" } else { "FAIL" }
            Complete-Phase "CONVERGENCE" $ps $status "Health at ${currentHealth}%"
        } else {
            Write-PipelineLog "gsd-existing.ps1 not found" -Level ERROR
            Complete-Phase "CONVERGENCE" $ps "SKIP" "Convergence script not found"
        }
    }
}

# ============================================================
# PHASE 2: BUILD GATE
# ============================================================

if ($startIndex -le 1 -and -not $SkipBuildGate) {
    $ps = Start-Phase "BUILD-GATE" "Compile check + auto-fix (dotnet build + npm run build)"

    $buildGateScript = Join-Path $ScriptsDir "gsd-build-gate.ps1"
    if (Test-Path $buildGateScript) {
        & pwsh -File $buildGateScript -RepoRoot $RepoRoot -FixModel claude -MaxAttempts $MaxCycles

        $bgReport = Join-Path $GsdDir "build-gate\build-gate-report.json"
        if (Test-Path $bgReport) {
            $bgData = Get-Content $bgReport -Raw | ConvertFrom-Json
            $status = if ($bgData.status -eq "pass") { "PASS" } else { "FAIL" }
            Complete-Phase "BUILD-GATE" $ps $status "Build $($bgData.status) on attempt $($bgData.attempts) of $($bgData.max_attempts)"
        } else {
            Complete-Phase "BUILD-GATE" $ps "WARN" "Build gate report not found"
        }
    } else {
        Write-PipelineLog "gsd-build-gate.ps1 not found" -Level ERROR
        Complete-Phase "BUILD-GATE" $ps "SKIP" "Script not found"
    }
}

# ============================================================
# PHASE 3: WIRE-UP
# ============================================================

if ($startIndex -le 2 -and -not $SkipWireUp) {
    $ps = Start-Phase "WIRE-UP" "Mock data scan, route-role matrix, integration wiring"

    # Mock data scan (local, free)
    $mockDetector = Join-Path $v3Dir "lib\modules\mock-data-detector.ps1"
    $mockCount = 0
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
    $matrixCount = 0
    $gapCount = 0
    if (Test-Path $routeMatrixMod) {
        . $routeMatrixMod
        $matrix = Build-RouteRoleMatrix -RepoRoot $RepoRoot
        if ($matrix) {
            $matrixCount = $matrix.Count
            $gapCount = ($matrix | Where-Object { $_.guard_type -eq 'none' -or $_.required_roles.Count -eq 0 }).Count
            Write-PipelineLog "Route-role matrix: $matrixCount routes, $gapCount gaps" -Level $(if ($gapCount -gt 0) { "WARN" } else { "OK" })
            Format-RouteRoleMatrix -Matrix $matrix
            $outDir = Join-Path $GsdDir "smoke-test"
            if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
            Export-RouteRoleMatrix -Matrix $matrix -OutputPath (Join-Path $outDir "route-role-matrix.json")
        }
    }

    # Wire-up code review pass (focused on integration issues)
    # Only run wire-up code review if code review phase is not skipped
    if (-not $SkipCodeReview) {
        Write-PipelineLog "Running wire-up review pass..."
        & pwsh -File (Join-Path $ScriptsDir "gsd-codereview.ps1") -RepoRoot $RepoRoot -MaxCycles 1 -MaxReqs $MaxReqs -FixModel claude -MinSeverityToFix high
    } else {
        Write-PipelineLog "Wire-up review skipped (code review disabled)" -Level SKIP
    }

    Complete-Phase "WIRE-UP" $ps "DONE" "Mock scan ($mockCount issues) + route matrix ($matrixCount routes, $gapCount gaps)"
}

# ============================================================
# PHASE 4: CODE REVIEW
# ============================================================

if ($startIndex -le 3 -and -not $SkipCodeReview) {
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
# PHASE 5: BUILD VERIFY
# ============================================================

if ($startIndex -le 4 -and -not $SkipBuildGate) {
    $ps = Start-Phase "BUILD-VERIFY" "Re-run build gate to confirm review fixes compile"

    $buildGateScript = Join-Path $ScriptsDir "gsd-build-gate.ps1"
    if (Test-Path $buildGateScript) {
        & pwsh -File $buildGateScript -RepoRoot $RepoRoot -FixModel claude -MaxAttempts 2

        $bgReport = Join-Path $GsdDir "build-gate\build-gate-report.json"
        if (Test-Path $bgReport) {
            $bgData = Get-Content $bgReport -Raw | ConvertFrom-Json
            $status = if ($bgData.status -eq "pass") { "PASS" } else { "FAIL" }
            Complete-Phase "BUILD-VERIFY" $ps $status "Build $($bgData.status) on attempt $($bgData.attempts)"
        } else {
            Complete-Phase "BUILD-VERIFY" $ps "WARN" "Report not found"
        }
    } else {
        Complete-Phase "BUILD-VERIFY" $ps "SKIP" "Script not found"
    }
}

# ============================================================
# PHASE 6: RUNTIME VALIDATION
# ============================================================

# Check if build passed before attempting runtime validation
$buildPassed = $false
foreach ($k in $phaseResults.Keys) {
    if ($k -match 'BUILD') {
        if ($phaseResults[$k].status -eq 'PASS') { $buildPassed = $true }
    }
}

if ($startIndex -le 5 -and -not $SkipRuntime -and ($buildPassed -or $startIndex -eq 5)) {
    $ps = Start-Phase "RUNTIME" "Start services, test endpoints, validate CRUD"

    $runtimeScript = Join-Path $ScriptsDir "gsd-runtime-validate.ps1"
    if (Test-Path $runtimeScript) {
        $rtParams = @("-RepoRoot", $RepoRoot, "-BackendPort", "$BackendPort", "-FrontendPort", "$FrontendPort", "-FixModel", "claude")
        if ($ConnectionString) { $rtParams += @("-ConnectionString", $ConnectionString) }
        if ($TestUsers) { $rtParams += @("-TestUsers", $TestUsers) }
        if ($AzureAdConfig) { $rtParams += @("-AzureAdConfig", $AzureAdConfig) }

        & pwsh -File $runtimeScript @rtParams

        $rtReport = Join-Path $GsdDir "runtime-validation\runtime-validation-report.json"
        if (Test-Path $rtReport) {
            $rtData = Get-Content $rtReport -Raw | ConvertFrom-Json
            $failCount = $rtData.summary.failed
            $passCount = $rtData.summary.passed
            $status = if ($failCount -eq 0) { "PASS" } elseif ($failCount -lt 5) { "WARN" } else { "FAIL" }
            Complete-Phase "RUNTIME" $ps $status "$passCount passed, $failCount failed"
        } else {
            Complete-Phase "RUNTIME" $ps "WARN" "Report not found"
        }
    } else {
        Write-PipelineLog "gsd-runtime-validate.ps1 not found" -Level ERROR
        Complete-Phase "RUNTIME" $ps "SKIP" "Script not found"
    }
}

# ============================================================
# PHASE 7: SMOKE TEST
# ============================================================

if ($startIndex -le 6 -and -not $SkipSmokeTest) {
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
# PHASE 8: FINAL REVIEW
# ============================================================

if ($startIndex -le 7 -and -not $SkipFinalReview) {
    $ps = Start-Phase "FINAL-REVIEW" "Post-smoke-test verification (fix all severities)"

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
# PHASE 9: DEV HANDOFF
# ============================================================

if ($startIndex -le 8) {
    $ps = Start-Phase "DEV-HANDOFF" "Generate handoff documentation"

    $totalDuration = (Get-Date) - $startTime
    $handoffDoc = "# $repoName - Pipeline V4 Handoff Report`n"
    $handoffDoc += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n`n"
    $handoffDoc += "## Pipeline Summary`n"
    $handoffDoc += "| Phase | Status | Duration | Summary |`n"
    $handoffDoc += "|-------|--------|----------|---------|`n"

    foreach ($phaseName in $phases) {
        $key = $phaseName.ToUpper() -replace 'BUILDGATE','BUILD-GATE' -replace 'BUILDVERIFY','BUILD-VERIFY' -replace 'CODEREVIEW','CODE-REVIEW' -replace 'SMOKETEST','SMOKE-TEST' -replace 'FINALREVIEW','FINAL-REVIEW'
        # Check both formats
        $r = $null
        foreach ($k in $phaseResults.Keys) {
            if ($k -eq $key -or $k -eq $phaseName.ToUpper()) { $r = $phaseResults[$k]; break }
        }
        if ($r) {
            $handoffDoc += "| $key | $($r.status) | $([math]::Round($r.duration, 1)) min | $($r.summary) |`n"
        }
    }

    $handoffDoc += "`n## Total Duration: $([math]::Round($totalDuration.TotalMinutes, 1)) minutes`n`n"

    $handoffDoc += "## Output Files`n"
    $handoffDoc += "- Build Gate: .gsd/build-gate/build-gate-report.json`n"
    $handoffDoc += "- Code Review: .gsd/code-review/review-summary.md`n"
    $handoffDoc += "- Runtime Validation: .gsd/runtime-validation/runtime-validation-summary.md`n"
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
