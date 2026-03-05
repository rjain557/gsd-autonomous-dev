<#
.SYNOPSIS
    Final Integration Sub-Patch 1/6: Spec Consistency Pre-Check
    Fixes GAP 5 + 15: Detect contradictions BEFORE wasting iterations
#>
param([string]$UserHome = $env:USERPROFILE)
$ErrorActionPreference = "Stop"
$LibFile = Join-Path $UserHome ".gsd-global\lib\modules\resilience.ps1"

if (-not (Test-Path $LibFile)) {
    Write-Host "Run prior patches first." -ForegroundColor Red; exit 1
}

Write-Host "[SEARCH] Sub-patch 1/6: Spec consistency pre-check..." -ForegroundColor Yellow

$code = @'

# ===============================================================
# SPEC CONSISTENCY CHECK - catches contradictions before iterating
# ===============================================================

function Invoke-SpecConsistencyCheck {
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [array]$Interfaces,
        [switch]$DryRun
    )

    Write-Host "  [CLIP] Spec consistency pre-check..." -ForegroundColor Cyan

    $specSources = @()
    $docsPath = Join-Path $RepoRoot "docs"
    if (Test-Path $docsPath) { $specSources += "docs\ (SDLC Phase A-E)" }

    foreach ($iface in $Interfaces) {
        if ($iface.HasAnalysis) {
            $specSources += "$($iface.VersionPath)\_analysis\ ($($iface.Label) - $($iface.AnalysisFileCount) deliverables)"
        }
    }

    if ($specSources.Count -eq 0) {
        Write-Host "    [!!]  No spec sources found. Skipping." -ForegroundColor DarkYellow
        return @{ Passed = $true; Conflicts = @(); Warnings = @() }
    }

    $sourceList = ($specSources | ForEach-Object { "- $_" }) -join "`n"

    $prompt = @"
You are a SPEC AUDITOR. Fast consistency check across all specification documents.
Runs BEFORE code generation - catch conflicts that would waste iterations.

## Spec Sources
$sourceList

## Check For
1. Data type conflicts: Same entity defined differently across docs
2. API contract conflicts: Same endpoint with different signatures
3. Navigation conflicts: Same route mapped to different screens
4. Business rule conflicts: Contradictory requirements
5. Design system conflicts: Different values for same token across interfaces
6. Database conflicts: Same table defined with different columns
7. Missing cross-refs: endpoint in hooks but not in API contracts

## Output
Write to: $GsdDir\spec-consistency-report.json
{
  "status": "pass|conflicts_found|warnings_only",
  "conflicts": [
    {
      "severity": "critical|warning",
      "type": "data_type|api_contract|navigation|business_rule|design_system|database|missing_ref",
      "description": "What conflicts",
      "source_a": "File A, section",
      "source_b": "File B, section",
      "recommendation": "How to resolve"
    }
  ],
  "summary": { "total_conflicts": N, "critical": N, "warnings": N, "specs_checked": N }
}

Also write: $GsdDir\spec-consistency-report.md

Rules: Be FAST. Only flag REAL conflicts. Under 2000 tokens output.
"@

    if ($DryRun) {
        Write-Host "    [DRY RUN] claude -> spec check" -ForegroundColor DarkYellow
        return @{ Passed = $true; Conflicts = @(); Warnings = @() }
    }

    $result = Invoke-WithRetry -Agent "claude" -Prompt $prompt -Phase "spec-consistency" `
        -LogFile "$GsdDir\logs\spec-consistency.log" -CurrentBatchSize 1 -GsdDir $GsdDir -MaxAttempts 2

    if (-not $result.Success) {
        Write-Host "    [!!]  Spec check failed - proceeding anyway" -ForegroundColor DarkYellow
        return @{ Passed = $true; Conflicts = @(); Warnings = @() }
    }

    $reportFile = Join-Path $GsdDir "spec-consistency-report.json"
    if (Test-Path $reportFile) {
        try {
            $report = Get-Content $reportFile -Raw | ConvertFrom-Json
            $criticals = @($report.conflicts | Where-Object { $_.severity -eq "critical" })
            $warnings = @($report.conflicts | Where-Object { $_.severity -eq "warning" })

            if ($criticals.Count -gt 0) {
                Write-Host "    [XX] $($criticals.Count) CRITICAL conflicts:" -ForegroundColor Red
                foreach ($c in $criticals) {
                    Write-Host "      - [$($c.type)] $($c.description)" -ForegroundColor Red
                }

                # Always write conflicts to file for review or auto-resolution
                $conflictsDir = Join-Path $GsdDir "spec-conflicts"
                if (-not (Test-Path $conflictsDir)) { New-Item -ItemType Directory -Path $conflictsDir -Force | Out-Null }
                @{
                    generated_at = (Get-Date -Format "o")
                    total_critical = $criticals.Count
                    total_warnings = $warnings.Count
                    conflicts = @($criticals) + @($warnings | Where-Object { $_ })
                } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $conflictsDir "conflicts-to-resolve.json") -Encoding UTF8
                Write-Host "    [>>]  Written to: .gsd\spec-conflicts\conflicts-to-resolve.json" -ForegroundColor DarkGray

                Write-Host "    [BLOCK] Fix these in your specs or use -AutoResolve to auto-fix." -ForegroundColor Red
                return @{ Passed = $false; Conflicts = $criticals; Warnings = $warnings }
            }

            if ($warnings.Count -gt 0) {
                Write-Host "    [!!]  $($warnings.Count) warnings (non-blocking)" -ForegroundColor DarkYellow
            }

            Write-Host "    [OK] Spec consistency passed" -ForegroundColor Green
            return @{ Passed = $true; Conflicts = @(); Warnings = $warnings }
        } catch {
            Write-Host "    [!!]  Could not parse report - proceeding" -ForegroundColor DarkYellow
        }
    }

    return @{ Passed = $true; Conflicts = @(); Warnings = @() }
}
'@

$existing = Get-Content $LibFile -Raw
if ($existing -match "SPEC CONSISTENCY CHECK") {
    # Remove old section and replace
    $idx = $existing.IndexOf("`n# SPEC CONSISTENCY CHECK")
    if ($idx -gt 0) {
        $existing = $existing.Substring(0, $idx)
        Set-Content -Path $LibFile -Value $existing -Encoding UTF8
    }
    Add-Content -Path $LibFile -Value "`n$code" -Encoding UTF8
    Write-Host "   [OK] Invoke-SpecConsistencyCheck updated" -ForegroundColor DarkGreen
} else {
    Add-Content -Path $LibFile -Value "`n$code" -Encoding UTF8
    Write-Host "   [OK] Invoke-SpecConsistencyCheck added" -ForegroundColor DarkGreen
}
