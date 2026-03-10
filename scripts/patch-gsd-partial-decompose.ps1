#Requires -Version 5.1
<#
.SYNOPSIS
    Patch #37 - Auto-decompose stuck partial requirements into atomic sub-requirements.

.DESCRIPTION
    At the start of each iteration's plan phase, checks which requirements from the
    previous batch are still partial (agent attempted but did not fully implement them).
    Uses Claude to decompose each stuck partial into 2-4 atomic sub-requirements that
    can each be fully implemented in a single iteration.

    Changes:
    1. Appends Invoke-PartialDecompose function to resilience.ps1
    2. Inserts call into convergence-loop.ps1 before plan phase prompt is built

.EXAMPLE
    .\patch-gsd-partial-decompose.ps1
#>

param(
    [string]$GlobalDir  = "$env:USERPROFILE\.gsd-global",
    [string]$ScriptsDir = $PSScriptRoot
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$resilienceFile  = "$GlobalDir\lib\modules\resilience.ps1"
$convergenceFile = "$GlobalDir\scripts\convergence-loop.ps1"
$snippetFile     = "$ScriptsDir\partials\invoke-partial-decompose.snippet.ps1"

Write-Host "Patch #37 - Auto-decompose stuck partial requirements" -ForegroundColor Cyan
Write-Host "  resilience.ps1  : $resilienceFile"
Write-Host "  convergence-loop: $convergenceFile"
Write-Host "  snippet file    : $snippetFile"

foreach ($f in @($resilienceFile, $convergenceFile, $snippetFile)) {
    if (-not (Test-Path $f)) { Write-Error "File not found: $f"; exit 1 }
}

# -----------------------------------------------------------------------------
# 1. Append Invoke-PartialDecompose to resilience.ps1
# -----------------------------------------------------------------------------
$resContent = [System.IO.File]::ReadAllText($resilienceFile)

if ($resContent -match 'function Invoke-PartialDecompose') {
    Write-Host "  [SKIP] Invoke-PartialDecompose already in resilience.ps1" -ForegroundColor Yellow
} else {
    $snippetContent = [System.IO.File]::ReadAllText($snippetFile)
    $appended = $resContent.TrimEnd() + [System.Environment]::NewLine + $snippetContent
    [System.IO.File]::WriteAllText($resilienceFile, $appended, [System.Text.Encoding]::UTF8)
    Write-Host "  [OK] Invoke-PartialDecompose appended to resilience.ps1" -ForegroundColor Green
}

# -----------------------------------------------------------------------------
# 2. Patch convergence-loop.ps1 - insert call before plan prompt is built
# -----------------------------------------------------------------------------
$convContent = [System.IO.File]::ReadAllText($convergenceFile)

if ($convContent -match 'Invoke-PartialDecompose') {
    Write-Host "  [SKIP] Invoke-PartialDecompose call already in convergence-loop.ps1" -ForegroundColor Yellow
} else {
    # Try multiple anchor patterns (plan prompt line may vary due to other patches)
    $anchors = @(
        '    $prompt = Local-ResolvePrompt "$GlobalDir\prompts\claude\plan.md" $Iteration $Health',
        '    $prompt = Local-ResolvePrompt "$GlobalDir\\prompts\\claude\\plan.md" $Iteration $Health'
    )
    $matchedAnchor = $null
    foreach ($a in $anchors) {
        if ($convContent.Contains($a)) { $matchedAnchor = $a; break }
    }
    # Fallback: regex search for plan.md prompt line
    if (-not $matchedAnchor) {
        if ($convContent -match '(?m)^(\s+\$prompt\s*=\s*Local-ResolvePrompt\s+.*plan\.md.*)$') {
            $matchedAnchor = $Matches[1]
            Write-Host "  [INFO] Found plan prompt line via regex: $matchedAnchor" -ForegroundColor DarkCyan
        }
    }

    if (-not $matchedAnchor) {
        Write-Host "  [WARN] Could not find plan prompt line in convergence-loop.ps1 — manual patch needed" -ForegroundColor Yellow
        Write-Host "  Add the following BEFORE the plan prompt line:" -ForegroundColor Yellow
        Write-Host '    if ($Iteration -gt 1 -and -not $DryRun -and (Get-Command Invoke-PartialDecompose -ErrorAction SilentlyContinue)) {' -ForegroundColor Gray
        Write-Host '        Invoke-PartialDecompose -GsdDir $GsdDir -GlobalDir $GlobalDir -Iteration $Iteration' -ForegroundColor Gray
        Write-Host '    }' -ForegroundColor Gray
    } else {
        $insertBlock  = "    # Auto-decompose stuck partials from previous iteration before planning" + [System.Environment]::NewLine
        $insertBlock += "    if (`$Iteration -gt 1 -and -not `$DryRun -and (Get-Command Invoke-PartialDecompose -ErrorAction SilentlyContinue)) {" + [System.Environment]::NewLine
        $insertBlock += "        Invoke-PartialDecompose -GsdDir `$GsdDir -GlobalDir `$GlobalDir -Iteration `$Iteration" + [System.Environment]::NewLine
        $insertBlock += "    }" + [System.Environment]::NewLine
        $insertBlock += $matchedAnchor

        $convContent = $convContent.Replace($matchedAnchor, $insertBlock)
        [System.IO.File]::WriteAllText($convergenceFile, $convContent)
        Write-Host "  [OK] Invoke-PartialDecompose call inserted into convergence-loop.ps1" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "Patch #37 complete." -ForegroundColor Green
Write-Host ""
Write-Host "How it works:" -ForegroundColor Cyan
Write-Host "  - Runs at start of each plan phase (iteration > 1)"
Write-Host "  - Reads queue-current.json (previous batch) to find which reqs were attempted"
Write-Host "  - Any that are still partial get decomposed via Claude into 2-4 atomic sub-reqs"
Write-Host "  - Sub-reqs added to requirements-matrix.json as not_started"
Write-Host "  - Parent marked decomposed=true so it is not re-decomposed next iteration"
Write-Host "  - Parent status stays partial (health formula unchanged until sub-reqs satisfy it)"
Write-Host "  - Log written to .gsd/logs/partial-decompose-iter{N}.json"
