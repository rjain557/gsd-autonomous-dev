<#
.SYNOPSIS
    GSD V3 Cost Tracker - Per-phase, per-model, per-requirement, per-interface cost tracking
.DESCRIPTION
    Tracks every API call cost in real-time. Enforces budget caps per pipeline mode.
    Fixes V2 issues:
    - V2 had no real-time cost tracking (only post-hoc estimates)
    - V2 had no budget enforcement (could run indefinitely)
    - V2 couldn't attribute cost to specific requirements or interfaces
#>

# ============================================================
# PRICING (per million tokens)
# ============================================================

$script:Pricing = @{
    "claude-sonnet-4-6" = @{
        input          = 3.00
        output         = 15.00
        cache_write    = 3.75
        cache_read     = 0.30
        batch_input    = 1.50
        batch_output   = 7.50
        batch_cache_read = 0.15
    }
    "claude-opus-4-6" = @{
        input          = 5.00
        output         = 25.00
        cache_write    = 6.25
        cache_read     = 0.50
        batch_input    = 2.50
        batch_output   = 12.50
        batch_cache_read = 0.25
    }
    "gpt-5.1-codex-mini" = @{
        input  = 0.25
        output = 2.00
    }
    "gpt-5.1-codex" = @{
        input  = 1.75
        output = 14.00
    }
    # Fallback models (OpenAI-compatible) -- prices verified 2026-03-10
    "deepseek-chat" = @{
        input  = 0.28
        output = 0.28
    }
    "moonshot-v1-8k" = @{
        input  = 0.20
        output = 2.00
    }
    "MiniMax-Text-01" = @{
        input  = 0.20
        output = 1.10
    }
}

# ============================================================
# STATE
# ============================================================

$script:CostState = @{
    TotalUsd        = 0.0
    ByPhase         = @{}
    ByModel         = @{}
    ByRequirement   = @{}
    ByInterface     = @{}
    ByMode          = @{}
    CacheHits       = 0
    CacheMisses     = 0
    BatchSavingsUsd = 0.0
    CallCount       = 0
    BudgetCapUsd    = 50.0
    Mode            = "greenfield"
}

# ============================================================
# INITIALIZATION
# ============================================================

function Initialize-CostTracker {
    param(
        [string]$Mode = "greenfield",
        [double]$BudgetCap = 50.0,
        [string]$GsdDir
    )

    $script:CostState.Mode = $Mode
    $script:CostState.BudgetCapUsd = $BudgetCap
    $script:CostState.TotalUsd = 0.0
    $script:CostState.CallCount = 0
    $script:CostState.ByPhase = @{}
    $script:CostState.ByModel = @{}
    $script:CostState.ByRequirement = @{}
    $script:CostState.ByInterface = @{}
    $script:CostState.ByMode = @{}
    $script:CostState.CacheHits = 0
    $script:CostState.CacheMisses = 0
    $script:CostState.BatchSavingsUsd = 0.0

    # Load existing cost state if resuming from checkpoint
    if ($GsdDir) {
        $costFile = Join-Path $GsdDir "costs/cost-summary.json"
        if (Test-Path $costFile) {
            try {
                $existing = Get-Content $costFile -Raw | ConvertFrom-Json
                $script:CostState.TotalUsd = $existing.total_usd
                $script:CostState.CallCount = $existing.call_count
                Write-Host "  [COST] Resumed from checkpoint: `$$([math]::Round($existing.total_usd, 4)) spent" -ForegroundColor DarkGray
            }
            catch {
                Write-Host "  [COST] Could not load existing cost state, starting fresh" -ForegroundColor DarkYellow
            }
        }
    }
}

# ============================================================
# COST CALCULATION
# ============================================================

function Add-ApiCallCost {
    <#
    .SYNOPSIS
        Record the cost of a single API call.
    .PARAMETER Model
        Model ID string.
    .PARAMETER Usage
        Usage object with input_tokens, output_tokens, cache_creation_tokens, cache_read_tokens.
    .PARAMETER Phase
        Phase name.
    .PARAMETER IsBatch
        Whether this call used the Batch API (50% discount).
    .PARAMETER RequirementId
        Optional requirement ID for attribution.
    .PARAMETER Interface
        Optional interface name for attribution.
    #>
    param(
        [string]$Model,
        [hashtable]$Usage,
        [string]$Phase,
        [switch]$IsBatch,
        [string]$RequirementId,
        [string]$Interface
    )

    if (-not $Usage) { return }
    if (-not $Model) { return }  # Skip cost tracking for failed calls with no model info

    $pricing = $script:Pricing[$Model]
    if (-not $pricing) {
        Write-Host "    [COST] Unknown model pricing: $Model" -ForegroundColor DarkYellow
        return
    }

    $cost = 0.0
    $regularCost = 0.0  # What it would have cost without optimizations

    $inputTokens = if ($Usage.input_tokens) { $Usage.input_tokens } else { 0 }
    $outputTokens = if ($Usage.output_tokens) { $Usage.output_tokens } else { 0 }
    $cacheWriteTokens = if ($Usage.cache_creation_tokens) { $Usage.cache_creation_tokens } else { 0 }
    $cacheReadTokens = if ($Usage.cache_read_tokens) { $Usage.cache_read_tokens } else { 0 }

    # Regular input (non-cached)
    $newInputTokens = $inputTokens - $cacheReadTokens - $cacheWriteTokens
    if ($newInputTokens -lt 0) { $newInputTokens = 0 }

    if ($IsBatch) {
        $cost += ($newInputTokens / 1000000) * $pricing.batch_input
        $cost += ($outputTokens / 1000000) * $pricing.batch_output
        if ($cacheReadTokens -gt 0 -and $pricing.batch_cache_read) {
            $cost += ($cacheReadTokens / 1000000) * $pricing.batch_cache_read
        }
        $regularCost = (($inputTokens / 1000000) * $pricing.input) + (($outputTokens / 1000000) * $pricing.output)
    }
    else {
        $cost += ($newInputTokens / 1000000) * $pricing.input
        $cost += ($outputTokens / 1000000) * $pricing.output
        if ($cacheReadTokens -gt 0 -and $pricing.cache_read) {
            $cost += ($cacheReadTokens / 1000000) * $pricing.cache_read
        }
        $regularCost = (($inputTokens / 1000000) * $pricing.input) + (($outputTokens / 1000000) * $pricing.output)
    }

    # Cache write cost
    if ($cacheWriteTokens -gt 0 -and $pricing.cache_write) {
        $cost += ($cacheWriteTokens / 1000000) * $pricing.cache_write
    }

    # Track cache hits/misses
    if ($cacheReadTokens -gt 0) { $script:CostState.CacheHits++ }
    elseif ($cacheWriteTokens -eq 0 -and $pricing.cache_read) { $script:CostState.CacheMisses++ }

    # Track batch savings
    if ($IsBatch) {
        $script:CostState.BatchSavingsUsd += ($regularCost - $cost)
    }

    # Accumulate
    $script:CostState.TotalUsd += $cost
    $script:CostState.CallCount++

    # By phase
    if (-not $script:CostState.ByPhase[$Phase]) { $script:CostState.ByPhase[$Phase] = 0.0 }
    $script:CostState.ByPhase[$Phase] += $cost

    # By model
    if (-not $script:CostState.ByModel[$Model]) { $script:CostState.ByModel[$Model] = 0.0 }
    $script:CostState.ByModel[$Model] += $cost

    # By requirement
    if ($RequirementId) {
        if (-not $script:CostState.ByRequirement[$RequirementId]) { $script:CostState.ByRequirement[$RequirementId] = 0.0 }
        $script:CostState.ByRequirement[$RequirementId] += $cost
    }

    # By interface
    if ($Interface) {
        if (-not $script:CostState.ByInterface[$Interface]) { $script:CostState.ByInterface[$Interface] = 0.0 }
        $script:CostState.ByInterface[$Interface] += $cost
    }

    # By mode
    $mode = $script:CostState.Mode
    if (-not $script:CostState.ByMode[$mode]) { $script:CostState.ByMode[$mode] = 0.0 }
    $script:CostState.ByMode[$mode] += $cost
}

# ============================================================
# BUDGET ENFORCEMENT
# ============================================================

function Test-BudgetAvailable {
    <#
    .SYNOPSIS
        Check if there's budget remaining. Returns $false if cap exceeded.
    .PARAMETER EstimatedCost
        Estimated cost of the next API call.
    #>
    param(
        [double]$EstimatedCost = 0.0
    )

    $remaining = $script:CostState.BudgetCapUsd - $script:CostState.TotalUsd

    # Warn at 80%
    $pctUsed = ($script:CostState.TotalUsd / [math]::Max($script:CostState.BudgetCapUsd, 0.01)) * 100
    if ($pctUsed -ge 80 -and $pctUsed -lt 100) {
        Write-Host "    [BUDGET] WARNING: $([math]::Round($pctUsed,1))% of `$$($script:CostState.BudgetCapUsd) budget used (`$$([math]::Round($script:CostState.TotalUsd, 4)) spent)" -ForegroundColor Yellow
    }

    if (($script:CostState.TotalUsd + $EstimatedCost) -gt $script:CostState.BudgetCapUsd) {
        Write-Host "    [BUDGET] EXCEEDED: `$$([math]::Round($script:CostState.TotalUsd, 4)) / `$$($script:CostState.BudgetCapUsd)" -ForegroundColor Red
        return $false
    }

    return $true
}

# ============================================================
# PERSISTENCE
# ============================================================

function Save-CostSummary {
    <#
    .SYNOPSIS
        Write cost summary to disk for checkpoint recovery and reporting.
    #>
    param(
        [string]$GsdDir
    )

    $costsDir = Join-Path $GsdDir "costs"
    if (-not (Test-Path $costsDir)) { New-Item -ItemType Directory -Path $costsDir -Force | Out-Null }

    $summary = @{
        total_usd          = [math]::Round($script:CostState.TotalUsd, 6)
        budget_cap_usd     = $script:CostState.BudgetCapUsd
        budget_remaining   = [math]::Round($script:CostState.BudgetCapUsd - $script:CostState.TotalUsd, 6)
        budget_pct_used    = [math]::Round(($script:CostState.TotalUsd / [math]::Max($script:CostState.BudgetCapUsd, 0.01)) * 100, 1)
        call_count         = $script:CostState.CallCount
        cache_hits         = $script:CostState.CacheHits
        cache_misses       = $script:CostState.CacheMisses
        batch_savings_usd  = [math]::Round($script:CostState.BatchSavingsUsd, 6)
        mode               = $script:CostState.Mode
        by_phase           = $script:CostState.ByPhase
        by_model           = $script:CostState.ByModel
        by_requirement     = $script:CostState.ByRequirement
        by_interface       = $script:CostState.ByInterface
        by_mode            = $script:CostState.ByMode
        timestamp          = (Get-Date -Format "o")
    }

    $summaryPath = Join-Path $costsDir "cost-summary.json"
    $summary | ConvertTo-Json -Depth 5 | Set-Content $summaryPath -Encoding UTF8

    # Also save mode-specific summary
    $modeFile = switch ($script:CostState.Mode) {
        "greenfield"     { "greenfield-summary.json" }
        "bug_fix"        { "bugfix-summary.json" }
        "feature_update" { "update-summary.json" }
        default          { "cost-summary.json" }
    }
    $summary | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $costsDir $modeFile) -Encoding UTF8
}

function Get-CostSummaryText {
    <#
    .SYNOPSIS
        Return a human-readable cost summary string.
    #>

    $lines = @()
    $lines += "Cost: `$$([math]::Round($script:CostState.TotalUsd, 4)) / `$$($script:CostState.BudgetCapUsd) ($([math]::Round(($script:CostState.TotalUsd / [math]::Max($script:CostState.BudgetCapUsd, 0.01)) * 100, 1))%)"
    $lines += "Calls: $($script:CostState.CallCount) | Cache hits: $($script:CostState.CacheHits) | Batch savings: `$$([math]::Round($script:CostState.BatchSavingsUsd, 4))"

    if ($script:CostState.ByPhase.Count -gt 0) {
        $lines += "By phase:"
        foreach ($phase in $script:CostState.ByPhase.Keys | Sort-Object) {
            $lines += "  $phase : `$$([math]::Round($script:CostState.ByPhase[$phase], 4))"
        }
    }

    return ($lines -join "`n")
}
