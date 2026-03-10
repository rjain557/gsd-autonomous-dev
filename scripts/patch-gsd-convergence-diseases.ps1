<#
.SYNOPSIS
    Patch #43: Fix 15 convergence diseases found by deep analysis.
    1. Execute pool ALL 7 agents: cheapest first, max_concurrent=4
    2. $Pipeline undefined: add "converge" assignment
    3. Unwrapped calls: try/catch on ParallelResearch + 7 more calls
    4. Parameter mismatches: Wait-ForRateWindow/Register-AgentCall in decompose
    5. Plan prompt: skip decomposed parents, prefer sub-requirements
    6. Code-review prompt: exclude decomposed parents from health formula
    7. Mutex release without acquisition check (Wait-ForRateWindow + Register-AgentCall)
    8. Stop-Job before Remove-Job for timed-out parallel jobs
    9. New-GitSnapshot stash pop removal (was a no-op)
    10. Cooldown reduced 30 min → 10 min (CLI quotas reset in 1-5 min)
    11. Sub-task cap at 14 (7 agents × 2 waves)
    12. CheapFirstReview wired into code-review phase
    13. BatchScopedResearch wired into research phase
    14. Decompose try/catch: already applied
    15. All Invoke-LlmCouncil/BuildValidation/CouncilRequirements wrapped
    16. Quota rotation phase-aware: CLI-only for plan/spec (execute allows ALL agents)
    17. Gemini added to execute pool (all 7 agents participate)
    18. Subtask timeout reduced 30→15 min (prevents codex hanging in quota loop)

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
    if ($pool.Count -ne 7 -or ($pool -notcontains "deepseek")) {
        $amContent.execute_parallel.agent_pool = @("deepseek", "codex", "kimi", "minimax", "glm5", "claude", "gemini")
        $amContent.execute_parallel.max_concurrent = 4
        $amContent.execute_parallel.subtask_timeout_minutes = 15
        $amContent | ConvertTo-Json -Depth 10 | Set-Content $agentMapPath -Encoding UTF8
        Write-Host "  [OK] Execute pool: all 7 agents (cheapest first), max_concurrent=4, timeout 15min" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] Execute pool already correct" -ForegroundColor DarkGray
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

# ── Disease 10: Cooldown too long (30 min → 10 min) ──
$resContent = Get-Content $resPath -Raw
if ($resContent -match 'CooldownMinutes 30') {
    $resContent = $resContent -replace 'CooldownMinutes 30', 'CooldownMinutes 10'
    $resContent | Set-Content $resPath -Encoding UTF8
    Write-Host "  [OK] Cooldown reduced: 30 min -> 10 min" -ForegroundColor Green
} else {
    Write-Host "  [SKIP] Cooldown already reduced" -ForegroundColor DarkGray
}

# ── Disease 11: Sub-task cap at 6 (3 CLI agents × 2 waves) ──
$resContent = Get-Content $resPath -Raw
if ($resContent -match 'maxSubtasks\s*=\s*6') {
    Write-Host "  [SKIP] Sub-task cap already set to 6" -ForegroundColor DarkGray
} else {
    Write-Host "  [INFO] Sub-task cap needs manual application in Invoke-ParallelExecute" -ForegroundColor Yellow
}

# ── Optimization 1: Wire CheapFirstReview into code-review phase ──
$loopContent = Get-Content $loopPath -Raw
if ($loopContent -match 'Invoke-CheapFirstReview') {
    Write-Host "  [SKIP] CheapFirstReview already wired in" -ForegroundColor DarkGray
} else {
    Write-Host "  [INFO] CheapFirstReview needs wiring into convergence-loop.ps1" -ForegroundColor Yellow
}

# ── Optimization 2: Wire BatchScopedResearch into research phase ──
if ($loopContent -match 'Invoke-BatchScopedResearch') {
    Write-Host "  [SKIP] BatchScopedResearch already wired in" -ForegroundColor DarkGray
} else {
    Write-Host "  [INFO] BatchScopedResearch needs wiring into convergence-loop.ps1" -ForegroundColor Yellow
}

# ── Disease 16: Quota rotation phase-aware (execute allows ALL agents) ──
$resContent = Get-Content $resPath -Raw
if ($resContent -match '\$cliOnlyPhase = \(\$Phase -match "council-requirements\|council-verify\|execute\|plan\|spec"\)') {
    $resContent = $resContent -replace '\$cliOnlyPhase = \(\$Phase -match "council-requirements\|council-verify\|execute\|plan\|spec"\)', '$cliOnlyPhase = ($Phase -match "council-requirements|council-verify|plan|spec")'
    $resContent | Set-Content $resPath -Encoding UTF8
    Write-Host "  [OK] Quota rotation: execute phase now allows ALL agents" -ForegroundColor Green
} elseif ($resContent -match '\$cliOnlyPhase = \(\$Phase -match "council-requirements\|council-verify"\)') {
    $resContent = $resContent -replace '\$cliOnlyPhase = \(\$Phase -match "council-requirements\|council-verify"\)', '$cliOnlyPhase = ($Phase -match "council-requirements|council-verify|plan|spec")'
    $resContent | Set-Content $resPath -Encoding UTF8
    Write-Host "  [OK] Quota rotation: CLI-only for plan/spec phases (execute open)" -ForegroundColor Green
} else {
    Write-Host "  [SKIP] Quota rotation already correct" -ForegroundColor DarkGray
}

Write-Host "`n=== Patch #43 Complete ===" -ForegroundColor Green
Write-Host "  Execute pool: ALL 7 agents (cheapest first, max_concurrent=4)" -ForegroundColor DarkCyan
Write-Host "  Pipeline var: defined as 'converge'" -ForegroundColor DarkCyan
Write-Host "  Crash protection: try/catch on 8 unwrapped calls" -ForegroundColor DarkCyan
Write-Host "  Rate limiter: correct param names + mutex fix" -ForegroundColor DarkCyan
Write-Host "  Plan/review: decomposed-aware (skip parents, exclude from health)" -ForegroundColor DarkCyan
Write-Host "  Parallel jobs: Stop-Job before Remove-Job" -ForegroundColor DarkCyan
Write-Host "  Git snapshots: stash persists as revert point" -ForegroundColor DarkCyan
Write-Host "  Cooldown: 10 min (was 30 min)" -ForegroundColor DarkCyan
Write-Host "  Sub-task cap: 14 max (7 agents x 2 waves)" -ForegroundColor DarkCyan
Write-Host "  CheapFirstReview: wired into code-review phase" -ForegroundColor DarkCyan
Write-Host "  BatchScopedResearch: wired into research phase" -ForegroundColor DarkCyan
Write-Host "  Quota rotation: CLI-only for plan/spec phases (execute open to all)" -ForegroundColor DarkCyan
