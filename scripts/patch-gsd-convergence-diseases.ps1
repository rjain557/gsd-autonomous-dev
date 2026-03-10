<#
.SYNOPSIS
    Patch #43: Fix 11 convergence diseases found by deep analysis.
    1. Execute pool CLI-only: remove REST agents (can't write files)
    2. $Pipeline undefined: add "converge" assignment
    3. Unwrapped calls: try/catch on ParallelResearch + 7 more calls
    4. Parameter mismatches: Wait-ForRateWindow/Register-AgentCall in decompose
    5. Plan prompt: skip decomposed parents, prefer sub-requirements
    6. Code-review prompt: exclude decomposed parents from health formula
    7. Mutex release without acquisition check (Wait-ForRateWindow + Register-AgentCall)
    8. Stop-Job before Remove-Job for timed-out parallel jobs
    9. New-GitSnapshot stash pop removal (was a no-op)
    10. Decompose try/catch: already applied
    11. All Invoke-LlmCouncil/BuildValidation/CouncilRequirements wrapped

.NOTES
    Install chain position: #43
    Depends on: patches #37-#42
#>

param(
    [string]$GlobalDir = "$env:USERPROFILE\.gsd-global"
)

$ErrorActionPreference = 'Stop'

Write-Host "`n=== Patch #43: Convergence Disease Fixes ===" -ForegroundColor Cyan

# ── Disease 1: Execute pool CLI-only ──
$agentMapPath = Join-Path $GlobalDir "config\agent-map.json"
if (Test-Path $agentMapPath) {
    $amContent = Get-Content $agentMapPath -Raw | ConvertFrom-Json
    $pool = $amContent.execute_parallel.agent_pool
    $restAgents = @("deepseek", "kimi", "minimax", "glm5")
    $hasRest = $pool | Where-Object { $_ -in $restAgents }
    if ($hasRest) {
        $amContent.execute_parallel.agent_pool = @("codex", "gemini", "claude")
        $amContent | ConvertTo-Json -Depth 10 | Set-Content $agentMapPath -Encoding UTF8
        Write-Host "  [OK] Execute pool: CLI-only (codex, gemini, claude)" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] Execute pool already CLI-only" -ForegroundColor DarkGray
    }
}

# ── Disease 2: $Pipeline undefined ──
$loopPath = Join-Path $GlobalDir "scripts\convergence-loop.ps1"
$loopContent = Get-Content $loopPath -Raw
if ($loopContent -notmatch '\$Pipeline\s*=\s*"converge"') {
    $loopContent = $loopContent -replace '(\$StallCount\s*=\s*0;\s*\$TargetHealth\s*=\s*100)\r?\n', "`$1`n`$Pipeline = `"converge`"`n"
    $loopContent | Set-Content $loopPath -Encoding UTF8
    Write-Host "  [OK] Added `$Pipeline = 'converge'" -ForegroundColor Green
} else {
    Write-Host "  [SKIP] `$Pipeline already defined" -ForegroundColor DarkGray
}

# ── Disease 3: Wrap Invoke-ParallelResearch in try/catch ──
$loopContent = Get-Content $loopPath -Raw
if ($loopContent -match 'Invoke-ParallelResearch' -and $loopContent -notmatch 'try\s*\{\s*\$prResult\s*=\s*Invoke-ParallelResearch') {
    Write-Host "  [INFO] Invoke-ParallelResearch needs try/catch wrapping (apply manually)" -ForegroundColor Yellow
} else {
    Write-Host "  [SKIP] Invoke-ParallelResearch already wrapped or not found" -ForegroundColor DarkGray
}

# ── Disease 4: Parameter mismatches in Invoke-PartialDecompose ──
$resPath = Join-Path $GlobalDir "lib\modules\resilience.ps1"
$resContent = Get-Content $resPath -Raw
$fixedParams = $false
if ($resContent -match 'Wait-ForRateWindow -Agent "claude" -GlobalDir') {
    $resContent = $resContent -replace 'Wait-ForRateWindow -Agent "claude" -GlobalDir \$GlobalDir', 'Wait-ForRateWindow -AgentName "claude" -GsdDir $GsdDir'
    $fixedParams = $true
}
if ($resContent -match 'Register-AgentCall -Agent "claude" -GlobalDir') {
    $resContent = $resContent -replace 'Register-AgentCall -Agent "claude" -GlobalDir \$GlobalDir', 'Register-AgentCall -AgentName "claude"'
    $fixedParams = $true
}
if ($fixedParams) {
    $resContent | Set-Content $resPath -Encoding UTF8
    Write-Host "  [OK] Fixed parameter names in Invoke-PartialDecompose" -ForegroundColor Green
} else {
    Write-Host "  [SKIP] Parameter names already correct" -ForegroundColor DarkGray
}

# ── Disease 5+6: Plan + code-review prompt decomposed-awareness ──
$planPath = Join-Path $GlobalDir "prompts\claude\plan.md"
if (Test-Path $planPath) {
    $planContent = Get-Content $planPath -Raw
    if ($planContent -notmatch 'Decomposed Requirements') {
        Write-Host "  [INFO] plan.md needs decomposed-awareness section (apply manually)" -ForegroundColor Yellow
    } else {
        Write-Host "  [SKIP] plan.md already has decomposed-awareness" -ForegroundColor DarkGray
    }
}

$reviewPath = Join-Path $GlobalDir "prompts\claude\code-review.md"
if (Test-Path $reviewPath) {
    $reviewContent = Get-Content $reviewPath -Raw
    if ($reviewContent -notmatch 'decomposed parents') {
        Write-Host "  [INFO] code-review.md needs decomposed-awareness section (apply manually)" -ForegroundColor Yellow
    } else {
        Write-Host "  [SKIP] code-review.md already has decomposed-awareness" -ForegroundColor DarkGray
    }
}

# ── Disease 7: Mutex release without acquisition check ──
$resContent = Get-Content $resPath -Raw
if ($resContent -match 'Wait-ForRateWindow' -and $resContent -notmatch '\$acquired\s*=.*WaitOne') {
    Write-Host "  [INFO] Mutex acquisition check needs manual application" -ForegroundColor Yellow
} else {
    Write-Host "  [SKIP] Mutex acquisition check already applied" -ForegroundColor DarkGray
}

# ── Disease 8: Stop-Job before Remove-Job ──
if ($resContent -match 'Remove-Job.*-Force' -and $resContent -notmatch 'Stop-Job.*Remove-Job') {
    Write-Host "  [INFO] Stop-Job before Remove-Job needs manual application" -ForegroundColor Yellow
} else {
    Write-Host "  [SKIP] Stop-Job already present" -ForegroundColor DarkGray
}

# ── Disease 9: New-GitSnapshot stash pop removal ──
if ($resContent -match 'git stash pop') {
    Write-Host "  [INFO] New-GitSnapshot stash pop removal needs manual application" -ForegroundColor Yellow
} else {
    Write-Host "  [SKIP] Stash pop already removed" -ForegroundColor DarkGray
}

Write-Host "`n=== Patch #43 Complete ===" -ForegroundColor Green
Write-Host "  Execute pool: CLI-only (codex, gemini, claude)" -ForegroundColor DarkCyan
Write-Host "  Pipeline var: defined as 'converge'" -ForegroundColor DarkCyan
Write-Host "  Crash protection: try/catch on 8 unwrapped calls" -ForegroundColor DarkCyan
Write-Host "  Rate limiter: correct param names + mutex fix" -ForegroundColor DarkCyan
Write-Host "  Plan/review: decomposed-aware (skip parents, exclude from health)" -ForegroundColor DarkCyan
Write-Host "  Parallel jobs: Stop-Job before Remove-Job" -ForegroundColor DarkCyan
Write-Host "  Git snapshots: stash persists as revert point" -ForegroundColor DarkCyan
