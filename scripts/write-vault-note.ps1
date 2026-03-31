#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Write an iteration summary note to the GSD Obsidian vault.

.DESCRIPTION
    Called automatically after each pipeline iteration.
    Writes a structured note to the vault's 06-Sessions/ folder
    and updates the project index health line.

.EXAMPLE
    pwsh -File scripts/write-vault-note.ps1 `
        -VaultRoot "D:\obsidian\gsd-autonomous-dev\gsd-autonomous-dev" `
        -Project "chatai-v8" `
        -Iteration 29 `
        -HealthBefore 19.4 `
        -HealthAfter 22.1 `
        -CostIter 0.91 `
        -CostCumulative 28.16 `
        -Notes "Auto-promoted 3 reqs via file check"
#>

param(
    [string]$VaultRoot  = "D:\obsidian\gsd-autonomous-dev\gsd-autonomous-dev",
    [string]$Project    = "",       # e.g. "chatai-v8"
    [int]   $Iteration  = 0,
    [double]$HealthBefore = 0,
    [double]$HealthAfter  = 0,
    [double]$CostIter   = 0,
    [double]$CostCumulative = 0,
    [int]   $ExecuteOK  = 0,
    [int]   $ValidatePass = 0,
    [int]   $ValidateFail = 0,
    [int]   $BlockedWrites = 0,
    [int]   $LLMFixCalls = 0,
    [int]   $Decompositions = 0,
    [int]   $Truncations = 0,
    [string]$Diseases   = "",       # comma-separated disease IDs detected
    [string]$Notes      = ""        # free-form iteration notes
)

if (-not $Project) { Write-Warning "write-vault-note: -Project is required"; exit 1 }
if (-not (Test-Path $VaultRoot)) { Write-Warning "write-vault-note: VaultRoot not found: $VaultRoot"; exit 1 }

$date       = Get-Date -Format "yyyy-MM-dd"
$time       = Get-Date -Format "HH:mm"
$iterPadded = $Iteration.ToString("000")
$healthDelta = [math]::Round($HealthAfter - $HealthBefore, 1)
$deltaStr   = if ($healthDelta -ge 0) { "+$healthDelta" } else { "$healthDelta" }
$prevIter   = ($Iteration - 1).ToString("000")
$nextIter   = ($Iteration + 1).ToString("000")

# ── 1. Write iteration note ────────────────────────────────────────────────
$sessionDir = Join-Path $VaultRoot "06-Sessions"
if (-not (Test-Path $sessionDir)) { New-Item -ItemType Directory $sessionDir | Out-Null }

$noteFile = Join-Path $sessionDir "$date-iter-$iterPadded-$Project.md"

$diseaseSection = if ($Diseases) {
    $Diseases -split "," | ForEach-Object { "- [[../../03-Patterns/diseases/$($_.Trim())|$($_.Trim())]]" } | Out-String
} else {
    "- None detected"
}

$noteContent = @"
---
type: iteration
project: $Project
iteration: $Iteration
date: $date
health_before: $HealthBefore
health_after: $HealthAfter
health_delta: $healthDelta
cost_iteration: $CostIter
cost_cumulative: $CostCumulative
tags: [iteration, $Project]
---

# Iteration $Iteration — $Project ($date $time)

## Health: $HealthBefore% → $HealthAfter% ($deltaStr%)

| Metric | Value |
|--------|-------|
| Cost this iter | `$`$CostIter |
| Cumulative cost | `$`$CostCumulative |
| Execute OK | $ExecuteOK |
| Validate PASS | $ValidatePass |
| Validate FAIL | $ValidateFail |
| BLOCKED writes | $BlockedWrites |
| LLM-FIX calls | $LLMFixCalls |
| Decompositions | $Decompositions |
| Truncations | $Truncations |

## Diseases Detected

$diseaseSection

## Notes

$Notes

## Links

- [[../../02-Projects/$Project/index|Project Index]]
- Previous: [[$date-iter-$prevIter-$Project]]
- Next: [[$date-iter-$nextIter-$Project]]
"@

Set-Content -Path $noteFile -Value $noteContent -Encoding UTF8
Write-Host "[Vault] Written: $noteFile"

# ── 2. Update project index health line ───────────────────────────────────
$projectIndex = Join-Path $VaultRoot "02-Projects\$Project\index.md"
if (Test-Path $projectIndex) {
    $content = Get-Content $projectIndex -Raw
    # Update the health field in frontmatter
    $content = $content -replace '(?m)^health:.*$', "health: $HealthAfter"
    # Update the table row
    $content = $content -replace '(?m)^\| Health \|.*$', "| Health | $HealthAfter% |"
    Set-Content -Path $projectIndex -Value $content -Encoding UTF8
    Write-Host "[Vault] Updated project index: $projectIndex"
}

# ── 3. Append to sessions index ───────────────────────────────────────────
$sessionsIndex = Join-Path $VaultRoot "06-Sessions\index.md"
if (-not (Test-Path $sessionsIndex)) {
    Set-Content $sessionsIndex "# Sessions`n`n| Date | Project | Iter | Health | Delta | Cost |`n|------|---------|------|--------|-------|------|`n" -Encoding UTF8
}
$row = "| $date | [[$date-iter-$iterPadded-$Project\|$Project iter $Iteration]] | $Iteration | $HealthAfter% | $deltaStr% | `$`$$CostIter |"
Add-Content $sessionsIndex $row -Encoding UTF8
Write-Host "[Vault] Appended to sessions index"

Write-Host "[Vault] Done. Iteration $Iteration note written for $Project"
