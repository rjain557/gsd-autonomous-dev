<#
.SYNOPSIS
    Patch: Fix false "converged" exit + orphaned profile code

    Fix 1: convergence-loop.ps1 — $TargetHealth/$StallCount initialized BEFORE try block
           so the finally block never sees $null (coerced to 0), preventing false convergence.

    Fix 2: gsd-profile-functions.ps1 — Remove orphaned statements outside function bodies
           (leftover from old gsd-converge and gsd-blueprint refactors).
#>
param([string]$UserHome = $env:USERPROFILE)
$ErrorActionPreference = "Stop"
$ScriptDir = Join-Path $UserHome ".gsd-global\scripts"

Write-Host ""
Write-Host "Patch: Fix false converge exit + orphaned profile code" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan

# ── Fix 1: convergence-loop.ps1 ──────────────────────────────────────────────
$loopFile = Join-Path $ScriptDir "convergence-loop.ps1"
if (Test-Path $loopFile) {
    $content = Get-Content $loopFile -Raw

    # Move initialization before try block (if not already patched)
    if ($content -match 'trap \{ Remove-GsdLock.*\}\s*\r?\ntry \{' -and $content -notmatch '# Initialize BEFORE try') {
        $content = $content -replace `
            '(trap \{ Remove-GsdLock[^\r\n]*\})', `
            "# Initialize BEFORE try so finally block always has valid values`r`n`$StallCount = 0; `$TargetHealth = 100; `$Iteration = 0`r`n`r`n`$1"
        Write-Host "  [OK] Moved StallCount/TargetHealth/Iteration init before try block" -ForegroundColor Green
    } else {
        Write-Host "  [>>] convergence-loop.ps1 already patched or structure changed" -ForegroundColor DarkGray
    }

    # Remove redundant initialization inside try (after "# Main loop")
    if ($content -match '# Main loop\s*\r?\n\$StallCount = 0; \$TargetHealth = 100\s*\r?\n') {
        $content = $content -replace '(# Main loop)\s*\r?\n\$StallCount = 0; \$TargetHealth = 100\s*\r?\n', "`$1`r`n"
        Write-Host "  [OK] Removed redundant StallCount/TargetHealth from main loop section" -ForegroundColor Green
    }

    Set-Content -Path $loopFile -Value $content -Encoding UTF8
    Write-Host "  [OK] convergence-loop.ps1 updated" -ForegroundColor Green
} else {
    Write-Host "  [!!] convergence-loop.ps1 not found at $loopFile" -ForegroundColor Red
}

# ── Fix 2: gsd-profile-functions.ps1 ─────────────────────────────────────────
$profileFile = Join-Path $ScriptDir "gsd-profile-functions.ps1"
if (Test-Path $profileFile) {
    $content = Get-Content $profileFile -Raw
    $changed = $false

    # Remove orphaned gsd-converge block (lines after closing } of gsd-converge function)
    $pattern1 = '(-NoSupervisor:\$NoSupervisor\s*\r?\n\})\s*\r?\n\s+if \(\$DryRun\).*?convergence-loop\.ps1" @params\s*\r?\n\}'
    if ($content -match $pattern1) {
        $content = $content -replace $pattern1, '$1'
        $changed = $true
        Write-Host "  [OK] Removed orphaned gsd-converge block" -ForegroundColor Green
    }

    # Remove orphaned gsd-blueprint block (lines after closing } of gsd-blueprint function)
    $pattern2 = '(-NoSupervisor:\$NoSupervisor\s*\r?\n\})\s*\r?\n\s+if \(\$DryRun\).*?blueprint-pipeline\.ps1" @params\s*\r?\n\}'
    if ($content -match $pattern2) {
        $content = $content -replace $pattern2, '$1'
        $changed = $true
        Write-Host "  [OK] Removed orphaned gsd-blueprint block" -ForegroundColor Green
    }

    if ($changed) {
        Set-Content -Path $profileFile -Value $content -Encoding UTF8
        Write-Host "  [OK] gsd-profile-functions.ps1 updated" -ForegroundColor Green
    } else {
        Write-Host "  [>>] gsd-profile-functions.ps1 already clean" -ForegroundColor DarkGray
    }
} else {
    Write-Host "  [!!] gsd-profile-functions.ps1 not found at $profileFile" -ForegroundColor Red
}

Write-Host ""
Write-Host "Done. Reload profile to pick up changes:" -ForegroundColor Yellow
Write-Host '  . "$env:USERPROFILE\.gsd-global\scripts\gsd-profile-functions.ps1"' -ForegroundColor Cyan
Write-Host ""
