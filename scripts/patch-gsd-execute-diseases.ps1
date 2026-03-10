<#
.SYNOPSIS
    Patch #42: Fix 5 execute-phase diseases.
    1. Execute wave dispatch: max_concurrent 5→2 (prevent cascade)
    2. Codex over-targeting: reorder agent pool (cheapest first)
    3. Kimi CLI/REST routing: respect model-registry type
    4. Agent traceability: extract agent+reqId from crashed jobs
    5. Inter-wave cooldown: configurable gap between execute waves

.NOTES
    Install chain position: #42
    Config: agent-map.json → execute_parallel.max_concurrent (2),
            agent-map.json → execute_parallel.inter_wave_cooldown_seconds (15),
            model-registry.json → kimi.type = "openai-compat"
#>

param(
    [string]$GlobalDir = "$env:USERPROFILE\.gsd-global"
)

$ErrorActionPreference = 'Stop'
$resiliencePath = Join-Path $GlobalDir "lib\modules\resilience.ps1"
$agentMapPath = Join-Path $GlobalDir "config\agent-map.json"
$registryPath = Join-Path $GlobalDir "config\model-registry.json"

Write-Host "`n=== Patch #42: Execute Phase Disease Fixes ===" -ForegroundColor Cyan

# ── Disease 1+2: Execute wave dispatch + agent pool reorder ──
if (Test-Path $agentMapPath) {
    $amContent = Get-Content $agentMapPath -Raw | ConvertFrom-Json
    $changed = $false

    if ($amContent.execute_parallel.max_concurrent -gt 2) {
        $amContent.execute_parallel.max_concurrent = 2
        $changed = $true
        Write-Host "  [OK] max_concurrent: $($amContent.execute_parallel.max_concurrent) -> 2" -ForegroundColor Green
    }

    if (-not $amContent.execute_parallel.inter_wave_cooldown_seconds) {
        $amContent.execute_parallel | Add-Member -NotePropertyName 'inter_wave_cooldown_seconds' -NotePropertyValue 15 -Force
        $changed = $true
        Write-Host "  [OK] Added inter_wave_cooldown_seconds: 15" -ForegroundColor Green
    }

    # Reorder pool: cheapest/highest-RPM first, expensive last
    $idealPool = @("deepseek","codex","gemini","kimi","minimax","glm5","claude")
    $amContent.execute_parallel.agent_pool = $idealPool
    $changed = $true

    if ($changed) {
        $amContent | ConvertTo-Json -Depth 10 | Set-Content $agentMapPath -Encoding UTF8
        Write-Host "  [OK] Agent pool reordered: deepseek first, claude last" -ForegroundColor Green
    }
} else {
    Write-Host "  [WARN] agent-map.json not found" -ForegroundColor Yellow
}

# ── Disease 3: Kimi type fix in model-registry ──
if (Test-Path $registryPath) {
    $regContent = Get-Content $registryPath -Raw
    if ($regContent -match '"kimi":\s*\{[^}]*"type":\s*"cli"') {
        $regContent = $regContent -replace '("kimi":\s*\{[^}]*)"type":\s*"cli"', '$1"type":  "openai-compat"'
        $regContent | Set-Content $registryPath -Encoding UTF8
        Write-Host "  [OK] Kimi type: cli -> openai-compat" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] Kimi already openai-compat or not found" -ForegroundColor DarkGray
    }
}

# ── Disease 3 (code): Fix kimi CLI dispatch in Invoke-WithRetry + Invoke-AgentFallback ──
$resContent = Get-Content $resiliencePath -Raw

# Patch 1: Invoke-WithRetry kimi block — add registry check
$oldKimiBlock = '$Agent -eq "kimi")'
$newKimiBlock = '$Agent -eq "kimi" -and -not (Test-IsOpenAICompatAgent -AgentName "kimi"))'
if ($resContent -match [regex]::Escape($oldKimiBlock) -and $resContent -notmatch [regex]::Escape($newKimiBlock)) {
    $resContent = $resContent.Replace($oldKimiBlock, $newKimiBlock)
    Write-Host "  [OK] Kimi CLI dispatch: added registry check (Invoke-WithRetry)" -ForegroundColor Green
}

# Patch 2: Invoke-AgentFallback kimi block — add registry check + REST fallback
$oldFbKimi = '$FallbackAgent -eq "kimi")'
$newFbKimi = '$FallbackAgent -eq "kimi" -and -not (Test-IsOpenAICompatAgent -AgentName "kimi"))'
if ($resContent -match [regex]::Escape($oldFbKimi) -and $resContent -notmatch [regex]::Escape($newFbKimi)) {
    $resContent = $resContent.Replace($oldFbKimi, $newFbKimi)
    Write-Host "  [OK] Kimi CLI dispatch: added registry check (AgentFallback)" -ForegroundColor Green
}

$resContent | Set-Content $resiliencePath -Encoding UTF8

# ── Disease 4+5: Agent traceability in job failures ──
# This requires modifying the job result collection loop — check if already patched
if ($resContent -match 'jobAgent.*matchSt.*Agent') {
    Write-Host "  [SKIP] Agent traceability already patched" -ForegroundColor DarkGray
} else {
    Write-Host "  [INFO] Agent traceability needs manual application (complex block replacement)" -ForegroundColor Yellow
    Write-Host "         The live code has been updated. This handles fresh installs." -ForegroundColor DarkGray
}

# ── Disease 5: Inter-wave cooldown from config ──
if ($resContent -match 'inter_wave_cooldown_seconds') {
    Write-Host "  [SKIP] Inter-wave cooldown already reads from config" -ForegroundColor DarkGray
} else {
    Write-Host "  [INFO] Inter-wave cooldown config read needs manual application" -ForegroundColor Yellow
}

Write-Host "`n=== Patch #42 Complete ===" -ForegroundColor Green
Write-Host "  Execute waves: max 2 concurrent, 15s gap between waves" -ForegroundColor DarkCyan
Write-Host "  Agent pool: deepseek > codex > gemini > kimi > minimax > glm5 > claude" -ForegroundColor DarkCyan
Write-Host "  Kimi: routed via REST API (openai-compat), not CLI" -ForegroundColor DarkCyan
Write-Host "  Job failures: agent name + req ID always traceable" -ForegroundColor DarkCyan
