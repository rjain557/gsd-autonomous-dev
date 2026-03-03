<#
.SYNOPSIS
    Token Cost Calculator for GSD Blueprint/Convergence Pipeline
    Estimates the API cost (if using pay-per-token) to complete a project to 100%.

.DESCRIPTION
    Calculates estimated token usage and equivalent API costs for all 3 LLMs:
      - Claude (Opus 4.6)    : Blueprint + Verify phases
      - Codex (GPT 5.3)     : Build phase (code generation)
      - Gemini (3.1 Pro)    : Research + Spec-fix phases

    Supports two modes:
      1. AUTO: Reads blueprint.json + health-history.jsonl from a project
      2. MANUAL: Uses parameters for estimation without a project

.PARAMETER ProjectPath
    Path to the project root containing .gsd\blueprint\. If omitted, uses current directory.

.PARAMETER TotalItems
    Manual override: total blueprint items (skips auto-read from blueprint.json).

.PARAMETER CompletedItems
    Manual override: number of completed items.

.PARAMETER BatchSize
    Items per build iteration. Default: 15.

.PARAMETER Pipeline
    Pipeline type: "blueprint" (3-phase) or "convergence" (5-phase). Default: "blueprint".

.PARAMETER BatchEfficiency
    Fraction of batch items that succeed per iteration (0.0-1.0). Default: 0.70.

.PARAMETER RetryRate
    Fraction of iterations that trigger a retry. Default: 0.15.

.PARAMETER ShowComparison
    Show side-by-side cost comparison of blueprint vs convergence pipelines.

.PARAMETER ClaudeModel
    Claude model for pricing. Options: "sonnet" (default), "opus", "haiku".

.EXAMPLE
    .\token-cost-calculator.ps1 -ProjectPath "C:\repos\my-app"
    # Auto-reads blueprint.json from the project

.EXAMPLE
    .\token-cost-calculator.ps1 -TotalItems 120 -CompletedItems 30 -ShowComparison
    # Manual estimate with pipeline comparison

.PARAMETER ClientQuote
    Generate a client-facing cost estimate. Applies a markup multiplier to cover
    estimation variance, subscription overhead, and margin. Default multiplier: 7.

.PARAMETER Markup
    Multiplier for client quote (used with -ClientQuote). Default: 7.
    Recommended: 5 (simple), 7 (medium), 10 (complex/enterprise).

.PARAMETER ClientName
    Client or project name for the quote header. Default: "Client Project".

.PARAMETER ShowActual
    Show actual token costs tracked from pipeline runs (reads .gsd/costs/cost-summary.json).
    When combined with estimation, shows an estimated-vs-actual comparison table.

.PARAMETER UpdatePricing
    Fetch latest pricing from provider websites and update the local cache.
    Pricing is cached at ~/.gsd-global/pricing-cache.json.

.EXAMPLE
    .\token-cost-calculator.ps1 -ShowActual
    # Show actual costs from pipeline runs

.EXAMPLE
    .\token-cost-calculator.ps1 -TotalItems 200 -Pipeline convergence -ClaudeModel opus
    # Convergence pipeline estimate with Opus pricing

.EXAMPLE
    .\token-cost-calculator.ps1 -TotalItems 300 -ClientQuote -Markup 8 -ClientName "Acme Corp"
    # Generate client quote with 8x markup

.EXAMPLE
    .\token-cost-calculator.ps1 -UpdatePricing
    # Fetch latest API pricing from all 3 providers
#>

param(
    [string]$ProjectPath = "",
    [int]$TotalItems = 0,
    [int]$CompletedItems = 0,
    [int]$PartialItems = 0,
    [int]$BatchSize = 15,
    [string]$Pipeline = "blueprint",
    [double]$BatchEfficiency = 0.70,
    [double]$RetryRate = 0.15,
    [switch]$ShowComparison,
    [string]$ClaudeModel = "sonnet",
    [switch]$Detailed,
    [switch]$ShowActual,
    [switch]$UpdatePricing,
    [switch]$ClientQuote,
    [double]$Markup = 7.0,
    [string]$ClientName = "Client Project"
)

# ============================================================================
# DYNAMIC PRICING - Fetched from provider websites, cached locally
# ============================================================================

$PricingCachePath = Join-Path $env:USERPROFILE ".gsd-global\pricing-cache.json"
$PricingCacheMaxAgeDays = 14  # Warn if older than this
$PricingCacheStaleAgeDays = 60  # Force update prompt if older than this

# Hardcoded fallback (used if no cache exists and fetch fails)
$FallbackPricing = @{
    lastUpdated = "2026-03-02T00:00:00Z"
    source      = "hardcoded-fallback"
    models      = @{
        claude_sonnet = @{ Name = "Claude Sonnet 4.6";              InputPerM = 3.00;  OutputPerM = 15.00; CacheReadPerM = 0.30  }
        claude_opus   = @{ Name = "Claude Opus 4.6";                InputPerM = 5.00;  OutputPerM = 25.00; CacheReadPerM = 0.50  }
        claude_haiku  = @{ Name = "Claude Haiku 4.5";               InputPerM = 1.00;  OutputPerM = 5.00;  CacheReadPerM = 0.10  }
        codex         = @{ Name = "GPT 5.3 Codex";                   InputPerM = 1.75;  OutputPerM = 14.00; CacheReadPerM = 0.175 }
        codex_gpt51   = @{ Name = "GPT-5.1 Codex";                  InputPerM = 1.25;  OutputPerM = 10.00; CacheReadPerM = 0.00  }
        gemini        = @{ Name = "Gemini 3.1 Pro";                  InputPerM = 2.00;  OutputPerM = 12.00; CacheReadPerM = 0.50  }
    }
}

function Get-ProviderPricing {
    <#
    .SYNOPSIS
        Fetches current API pricing from the LiteLLM open-source pricing database.
        This is a community-maintained JSON file with accurate prices for all major LLM providers,
        updated frequently at: github.com/BerriAI/litellm
    #>
    param([switch]$Silent)

    $litellmUrl = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"

    $updated = @{
        lastUpdated = (Get-Date).ToString("o")
        source      = "litellm-github"
        sourceUrl   = $litellmUrl
        models      = @{}
    }

    # Model keys to look up in LiteLLM data (ordered by preference: latest first)
    $modelLookups = @(
        @{ CacheKey = "claude_opus";   LiteLLMKeys = @("claude-opus-4-6","claude-opus-4-5","claude-opus-4-1"); NamePrefix = "Claude Opus" }
        @{ CacheKey = "claude_sonnet"; LiteLLMKeys = @("claude-sonnet-4-6","claude-sonnet-4-5","claude-sonnet-4"); NamePrefix = "Claude Sonnet" }
        @{ CacheKey = "claude_haiku";  LiteLLMKeys = @("claude-haiku-4-5","claude-3-5-haiku-latest"); NamePrefix = "Claude Haiku" }
        @{ CacheKey = "codex";         LiteLLMKeys = @("gpt-5.3-codex","codex-mini-latest"); NamePrefix = "GPT 5.3 Codex" }
        @{ CacheKey = "codex_gpt51";   LiteLLMKeys = @("gpt-5.1-codex","gpt-5-codex"); NamePrefix = "GPT Codex" }
        @{ CacheKey = "gemini";        LiteLLMKeys = @("gemini-3.1-pro-preview","gemini-3-pro-preview","gemini-2.5-pro"); NamePrefix = "Gemini 3.1 Pro" }
    )

    try {
        if (-not $Silent) { Write-Host "  Fetching pricing from LiteLLM database..." -NoNewline -ForegroundColor DarkGray }
        $response = Invoke-WebRequest -Uri $litellmUrl -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
        $data = $response.Content | ConvertFrom-Json -AsHashtable

        $foundCount = 0
        foreach ($lookup in $modelLookups) {
            foreach ($key in $lookup.LiteLLMKeys) {
                if ($data.ContainsKey($key)) {
                    $m = $data[$key]
                    $inputPerM  = [Math]::Round([double]$m.input_cost_per_token * 1000000, 2)
                    $outputPerM = [Math]::Round([double]$m.output_cost_per_token * 1000000, 2)

                    # Derive version from key name (skip if already in prefix)
                    $version = ""
                    if ($key -match '(\d+[\.\-]\d+)') {
                        $ver = $Matches[1] -replace '-','.'
                        if ($lookup.NamePrefix -notmatch [regex]::Escape($ver)) { $version = " $ver" }
                    }

                    $updated.models[$lookup.CacheKey] = @{
                        Name          = "$($lookup.NamePrefix)$version"
                        InputPerM     = $inputPerM
                        OutputPerM    = $outputPerM
                        CacheReadPerM = [Math]::Round($inputPerM * 0.1, 3)  # Cache reads ~10% of input
                        LiteLLMKey    = $key
                    }
                    $foundCount++
                    break  # Use first (latest) matching key
                }
            }
        }

        if (-not $Silent) { Write-Host " OK ($foundCount models found)" -ForegroundColor Green }
        if ($foundCount -ge 3) { return $updated }

    } catch {
        if (-not $Silent) { Write-Host " FAILED: $($_.Exception.Message)" -ForegroundColor Yellow }
    }

    if ($fetchedAny) {
        return $updated
    }
    return $null
}

function Get-LlmPricing {
    <#
    .SYNOPSIS
        Returns current LLM pricing. Reads from cache, fetches from web if stale, falls back to hardcoded.
    #>
    param([switch]$ForceUpdate)

    # Check cache
    if ((Test-Path $PricingCachePath) -and -not $ForceUpdate) {
        try {
            $cached = Get-Content $PricingCachePath -Raw | ConvertFrom-Json
            $cachedDate = if ($cached.lastUpdated -is [DateTime]) { $cached.lastUpdated } else { [DateTime]::Parse($cached.lastUpdated) }
            $cacheAge = (Get-Date) - $cachedDate

            $cachedDateStr = if ($cachedDate) { $cachedDate.ToString("yyyy-MM-dd") } else { "unknown" }
            if ($cacheAge.TotalDays -lt $PricingCacheMaxAgeDays) {
                # Cache is fresh
                Write-Host "[OK] Using cached pricing (updated $cachedDateStr, $([Math]::Floor($cacheAge.TotalDays))d ago)" -ForegroundColor DarkGreen
                return $cached
            }
            elseif ($cacheAge.TotalDays -lt $PricingCacheStaleAgeDays) {
                # Cache is aging, try to refresh
                Write-Host "[!!] Pricing cache is $([Math]::Floor($cacheAge.TotalDays)) days old, refreshing..." -ForegroundColor Yellow
                $fresh = Get-ProviderPricing
                if ($fresh -and $fresh.models.Count -ge 3) {
                    # Merge: keep cached values for any models we failed to fetch
                    foreach ($key in ($cached.models | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)) {
                        if (-not $fresh.models.ContainsKey($key)) {
                            $fresh.models[$key] = $cached.models.$key
                        }
                    }
                    Save-PricingCache $fresh
                    return $fresh
                }
                Write-Host "  Using cached pricing (refresh failed)" -ForegroundColor Yellow
                return $cached
            }
            else {
                # Cache is very stale
                Write-Host "[!!] Pricing cache is $([Math]::Floor($cacheAge.TotalDays)) days old! Run with -UpdatePricing to refresh." -ForegroundColor Red
                Write-Host "  Attempting auto-refresh..." -ForegroundColor Yellow
                $fresh = Get-ProviderPricing
                if ($fresh -and $fresh.models.Count -ge 3) {
                    Save-PricingCache $fresh
                    return $fresh
                }
                Write-Host "  Using stale cached pricing (refresh failed)" -ForegroundColor Yellow
                return $cached
            }
        } catch {
            Write-Host "[!!] Could not read pricing cache: $_" -ForegroundColor Yellow
        }
    }

    # No cache or force update - try fetching
    if ($ForceUpdate) {
        Write-Host ""
        Write-Host "  UPDATING PRICING FROM PROVIDER WEBSITES" -ForegroundColor Cyan
        Write-Host "  -----------------------------------------------"
    }
    $fresh = Get-ProviderPricing -Silent:(-not $ForceUpdate)
    if ($fresh -and $fresh.models.Count -ge 3) {
        Save-PricingCache $fresh
        if ($ForceUpdate) {
            Write-Host ""
            Write-Host "  Pricing updated successfully!" -ForegroundColor Green
            Write-Host "  Cached to: $PricingCachePath" -ForegroundColor DarkGray
            Write-Host ""
            # Show what we fetched
            foreach ($key in ($fresh.models.Keys | Sort-Object)) {
                $m = $fresh.models[$key]
                Write-Host ("  {0,-35} Input: `${1,-8:N2}/M   Output: `${2,-8:N2}/M" -f $m.Name, $m.InputPerM, $m.OutputPerM) -ForegroundColor White
            }
            Write-Host ""
        }
        return $fresh
    }

    # Fallback to hardcoded
    Write-Host "[!!] Could not fetch pricing. Using hardcoded fallback (March 2026)." -ForegroundColor Yellow
    return $FallbackPricing
}

function Save-PricingCache {
    param($PricingData)
    $cacheDir = Split-Path $PricingCachePath -Parent
    if (-not (Test-Path $cacheDir)) {
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    }
    # Convert hashtables to a serializable format
    $serializable = @{
        lastUpdated = $PricingData.lastUpdated
        source      = $PricingData.source
        models      = @{}
    }
    if ($PricingData.fetchUrls) { $serializable.fetchUrls = $PricingData.fetchUrls }
    foreach ($key in $PricingData.models.Keys) {
        $m = $PricingData.models[$key]
        $serializable.models[$key] = @{
            Name          = if ($m.Name) { $m.Name } else { $key }
            InputPerM     = if ($m.InputPerM) { $m.InputPerM } else { 0 }
            OutputPerM    = if ($m.OutputPerM) { $m.OutputPerM } else { 0 }
            CacheReadPerM = if ($m.CacheReadPerM) { $m.CacheReadPerM } else { 0 }
        }
    }
    $serializable | ConvertTo-Json -Depth 5 | Set-Content -Path $PricingCachePath -Encoding UTF8
}

# ============================================================================
# LOAD PRICING
# ============================================================================

if ($UpdatePricing) {
    $pricingData = Get-LlmPricing -ForceUpdate
    if ($TotalItems -eq 0) {
        # Just updating pricing, no calculation needed
        exit 0
    }
} else {
    $pricingData = Get-LlmPricing
}

# Extract model pricing from the loaded data (handle both hashtable and PSObject)
function Get-ModelPrice {
    param($Data, [string]$Key)
    $models = $Data.models
    $m = $null
    if ($models -is [hashtable]) {
        if ($models.ContainsKey($Key)) { $m = $models[$Key] }
    } else {
        $m = $models.$Key
    }
    if (-not $m) { return $null }
    # Normalize to hashtable
    @{
        Name          = if ($m.Name) { "$($m.Name)" } else { $Key }
        InputPerM     = [double]$(if ($m.InputPerM) { $m.InputPerM } else { 0 })
        OutputPerM    = [double]$(if ($m.OutputPerM) { $m.OutputPerM } else { 0 })
        CacheReadPerM = [double]$(if ($m.CacheReadPerM) { $m.CacheReadPerM } else { 0 })
    }
}

# Select Claude pricing based on model parameter
$claudeKey = "claude_$ClaudeModel"
$claudePricing = Get-ModelPrice $pricingData $claudeKey
if (-not $claudePricing) {
    Write-Host "Invalid Claude model: $ClaudeModel. Use: sonnet, opus, haiku" -ForegroundColor Red
    exit 1
}
$codexPricing  = Get-ModelPrice $pricingData "codex"
if (-not $codexPricing) { $codexPricing = $FallbackPricing.models["codex"] }
$geminiPricing = Get-ModelPrice $pricingData "gemini"
if (-not $geminiPricing) { $geminiPricing = $FallbackPricing.models["gemini"] }

# ============================================================================
# TOKEN ESTIMATES PER ITEM TYPE
# ============================================================================

# Average output tokens generated by Codex per blueprint item type
$TokensPerItemType = @{
    "sql-migration"     = 1000
    "stored_procedure"  = 2000
    "stored-procedure"  = 2000
    "controller"        = 5000
    "service"           = 3500
    "dto"               = 1500
    "component"         = 4000
    "react-component"   = 4000
    "hook"              = 2500
    "middleware"         = 2000
    "config"            = 1500
    "test"              = 3000
    "compliance"        = 2000
    "routing"           = 1500
    "default"           = 3500
}

# ============================================================================
# AUTO-READ FROM PROJECT (if available)
# ============================================================================

$projectHealthHistory = @()
$blueprintItems = @()
$autoDetected = $false

if (-not $ProjectPath) { $ProjectPath = Get-Location }

$blueprintJsonPath = Join-Path $ProjectPath ".gsd\blueprint\blueprint.json"
$healthHistoryPath = Join-Path $ProjectPath ".gsd\blueprint\health-history.jsonl"
$healthJsonPath    = Join-Path $ProjectPath ".gsd\blueprint\health.json"

# Try to read blueprint.json for item counts and types
if ($TotalItems -eq 0 -and (Test-Path $blueprintJsonPath)) {
    try {
        $blueprint = Get-Content $blueprintJsonPath -Raw | ConvertFrom-Json
        $allItems = @()
        foreach ($tier in $blueprint.tiers) {
            foreach ($item in $tier.items) {
                $allItems += $item
            }
        }
        $TotalItems     = $allItems.Count
        $CompletedItems = ($allItems | Where-Object { $_.status -eq "completed" }).Count
        $PartialItems   = ($allItems | Where-Object { $_.status -eq "partial" }).Count
        $blueprintItems = $allItems
        $autoDetected   = $true
        Write-Host "[OK] Auto-read blueprint.json: $TotalItems items ($CompletedItems completed, $PartialItems partial)" -ForegroundColor Green
    } catch {
        Write-Host "[!!] Could not parse blueprint.json: $_" -ForegroundColor Yellow
    }
}

# Try to read health-history.jsonl for progression rate
if (Test-Path $healthHistoryPath) {
    try {
        $lines = Get-Content $healthHistoryPath | Where-Object { $_.Trim() -ne "" }
        foreach ($line in $lines) {
            $entry = $line | ConvertFrom-Json
            $projectHealthHistory += $entry
        }
        if ($projectHealthHistory.Count -ge 2) {
            Write-Host "[OK] Auto-read health-history.jsonl: $($projectHealthHistory.Count) iterations" -ForegroundColor Green
        }
    } catch {
        Write-Host "[!!] Could not parse health-history.jsonl: $_" -ForegroundColor Yellow
    }
}

# Try to read current health
$currentHealth = 0.0
if (Test-Path $healthJsonPath) {
    try {
        $healthData = Get-Content $healthJsonPath -Raw | ConvertFrom-Json
        $currentHealth = [double]$healthData.health
    } catch {}
}

# ============================================================================
# VALIDATION
# ============================================================================

if ($TotalItems -le 0) {
    Write-Host ""
    Write-Host "ERROR: No blueprint.json found and -TotalItems not specified." -ForegroundColor Red
    Write-Host ""
    Write-Host "Usage:" -ForegroundColor Yellow
    Write-Host "  .\token-cost-calculator.ps1 -ProjectPath 'C:\repos\my-app'"
    Write-Host "  .\token-cost-calculator.ps1 -TotalItems 120 -CompletedItems 30"
    Write-Host "  .\token-cost-calculator.ps1 -TotalItems 200 -ShowComparison"
    exit 1
}

# ============================================================================
# CALCULATIONS
# ============================================================================

function Get-PipelineCost {
    param(
        [string]$PipelineType,
        [int]$Total,
        [int]$Completed,
        [int]$Partial,
        [int]$Batch,
        [double]$Efficiency,
        [double]$Retries,
        [hashtable]$ClaudePrices,
        [hashtable]$CodexPrices,
        [hashtable]$GeminiPrices,
        [array]$Items
    )

    $remaining = $Total - $Completed
    # Partial items count as 0.5 remaining (need fixes, not full generation)
    $effectiveRemaining = ($remaining - $Partial) + ($Partial * 0.5)

    # Items completed per successful iteration
    $itemsPerIter = [Math]::Max(1, [Math]::Floor($Batch * $Efficiency))

    # Estimated iterations (including retries)
    $baseIterations = [Math]::Ceiling($effectiveRemaining / $itemsPerIter)
    $retryIterations = [Math]::Ceiling($baseIterations * $Retries)
    $totalIterations = $baseIterations + $retryIterations

    # Context scaling: larger projects = larger input contexts
    $blueprintContextTokens = [Math]::Min(100000, $Total * 200 + 5000)
    $fileMapTokens = [Math]::Min(30000, $Total * 50)

    # Calculate average output tokens per item
    $avgOutputPerItem = 3500
    if ($Items.Count -gt 0) {
        $totalTokens = 0
        foreach ($item in $Items) {
            $itemType = if ($item.pattern) { $item.pattern } elseif ($item.type) { $item.type } else { "default" }
            if ($TokensPerItemType.ContainsKey($itemType)) {
                $totalTokens += $TokensPerItemType[$itemType]
            } else {
                $totalTokens += $TokensPerItemType["default"]
            }
        }
        $avgOutputPerItem = [Math]::Ceiling($totalTokens / $Items.Count)
    }

    # ---- PHASE TOKEN ESTIMATES ----

    $phases = @{}

    # Blueprint phase (Claude, once)
    $phases["Blueprint"] = @{
        Agent        = "Claude"
        InputTokens  = $blueprintContextTokens
        OutputTokens = [Math]::Min(15000, $Total * 100)
        Iterations   = 1
        Description  = "Architecture manifest (one-time)"
    }

    if ($PipelineType -eq "blueprint") {
        # Verify phase (Claude, per iteration)
        $phases["Verify"] = @{
            Agent        = "Claude"
            InputTokens  = $blueprintContextTokens + $fileMapTokens + 3000
            OutputTokens = 2500
            Iterations   = $totalIterations
            Description  = "Health scoring + batch selection"
        }

        # Build phase (Codex, per iteration)
        $phases["Build"] = @{
            Agent        = "Codex"
            InputTokens  = ($Batch * 300) + $fileMapTokens + 5000
            OutputTokens = $Batch * $avgOutputPerItem
            Iterations   = $totalIterations
            Description  = "Code generation ($Batch items/batch)"
        }

        # Gemini spec-fix (occasional)
        $phases["SpecFix"] = @{
            Agent        = "Gemini"
            InputTokens  = 12000
            OutputTokens = 4000
            Iterations   = [Math]::Max(1, [Math]::Floor($totalIterations * 0.15))
            Description  = "Spec conflict resolution (occasional)"
        }
    }
    elseif ($PipelineType -eq "convergence") {
        # 5-phase convergence loop: review -> research -> plan -> execute -> verify

        # Review (Claude)
        $phases["Review"] = @{
            Agent        = "Claude"
            InputTokens  = $blueprintContextTokens + $fileMapTokens + 3000
            OutputTokens = 3000
            Iterations   = $totalIterations
            Description  = "Code review + health scoring"
        }

        # Research (Gemini)
        $phases["Research"] = @{
            Agent        = "Gemini"
            InputTokens  = 25000 + $fileMapTokens
            OutputTokens = 6000
            Iterations   = $totalIterations
            Description  = "Pattern research (plan mode, read-only)"
        }

        # Plan (Claude)
        $phases["Plan"] = @{
            Agent        = "Claude"
            InputTokens  = 15000
            OutputTokens = 4000
            Iterations   = $totalIterations
            Description  = "Prioritization + generation instructions"
        }

        # Execute (Codex)
        $phases["Execute"] = @{
            Agent        = "Codex"
            InputTokens  = ($Batch * 300) + $fileMapTokens + 8000
            OutputTokens = $Batch * $avgOutputPerItem
            Iterations   = $totalIterations
            Description  = "Code generation ($Batch items/batch)"
        }

        # Verify (Claude)
        $phases["Verify"] = @{
            Agent        = "Claude"
            InputTokens  = $blueprintContextTokens + $fileMapTokens + 3000
            OutputTokens = 2500
            Iterations   = $totalIterations
            Description  = "Verification + drift detection"
        }

        # Spec-fix (Gemini, occasional)
        $phases["SpecFix"] = @{
            Agent        = "Gemini"
            InputTokens  = 12000
            OutputTokens = 4000
            Iterations   = [Math]::Max(1, [Math]::Floor($totalIterations * 0.2))
            Description  = "Spec conflict resolution"
        }
    }

    # ---- COST CALCULATION ----

    $totalCost = 0.0
    $totalInputTokens = 0
    $totalOutputTokens = 0
    $costByAgent = @{ Claude = 0.0; Codex = 0.0; Gemini = 0.0 }
    $tokensByAgent = @{
        Claude = @{ Input = 0; Output = 0 }
        Codex  = @{ Input = 0; Output = 0 }
        Gemini = @{ Input = 0; Output = 0 }
    }

    $phaseDetails = @()

    foreach ($phaseName in ($phases.Keys | Sort-Object)) {
        $phase = $phases[$phaseName]
        $agent = $phase.Agent
        $iters = $phase.Iterations
        $inTok  = $phase.InputTokens * $iters
        $outTok = $phase.OutputTokens * $iters

        # Select pricing
        $prices = switch ($agent) {
            "Claude" { $ClaudePrices }
            "Codex"  { $CodexPrices }
            "Gemini" { $GeminiPrices }
        }

        $inCost  = ($inTok / 1000000) * $prices.InputPerM
        $outCost = ($outTok / 1000000) * $prices.OutputPerM
        $phaseCost = $inCost + $outCost

        $totalCost += $phaseCost
        $totalInputTokens += $inTok
        $totalOutputTokens += $outTok
        $costByAgent[$agent] += $phaseCost
        $tokensByAgent[$agent].Input += $inTok
        $tokensByAgent[$agent].Output += $outTok

        $phaseDetails += [PSCustomObject]@{
            Phase      = $phaseName
            Agent      = $agent
            Iterations = $iters
            InputTok   = $inTok
            OutputTok  = $outTok
            Cost       = $phaseCost
            Desc       = $phase.Description
        }
    }

    return @{
        PipelineType      = $PipelineType
        TotalItems        = $Total
        RemainingItems    = $remaining
        PartialItems      = $Partial
        BatchSize         = $Batch
        BatchEfficiency   = $Efficiency
        TotalIterations   = $totalIterations
        BaseIterations    = $baseIterations
        RetryIterations   = $retryIterations
        AvgOutputPerItem  = $avgOutputPerItem
        TotalCost         = $totalCost
        TotalInputTokens  = $totalInputTokens
        TotalOutputTokens = $totalOutputTokens
        CostByAgent       = $costByAgent
        TokensByAgent     = $tokensByAgent
        PhaseDetails      = $phaseDetails
    }
}

# ============================================================================
# CALCULATE PRIMARY PIPELINE
# ============================================================================

$result = Get-PipelineCost `
    -PipelineType $Pipeline `
    -Total $TotalItems `
    -Completed $CompletedItems `
    -Partial $PartialItems `
    -Batch $BatchSize `
    -Efficiency $BatchEfficiency `
    -Retries $RetryRate `
    -ClaudePrices $claudePricing `
    -CodexPrices $codexPricing `
    -GeminiPrices $geminiPricing `
    -Items $blueprintItems

# ============================================================================
# OUTPUT
# ============================================================================

Write-Host ""
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "  GSD TOKEN COST CALCULATOR                                                 " -ForegroundColor Cyan
Write-Host "  Estimated API cost to reach 100% project completion                       " -ForegroundColor Cyan
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host ""

# Project Summary - prefer health.json value if auto-detected, else calculate
$healthPct = if ($currentHealth -gt 0) { [Math]::Round($currentHealth, 1) }
             elseif ($TotalItems -gt 0) { [Math]::Round(($CompletedItems / $TotalItems) * 100, 1) }
             else { 0 }
Write-Host "  PROJECT SUMMARY" -ForegroundColor White
Write-Host "  -----------------------------------------------"
Write-Host "  Pipeline:          $($Pipeline.ToUpper())" -ForegroundColor Yellow
Write-Host "  Total items:       $TotalItems"
Write-Host "  Completed:         $CompletedItems ($healthPct%)"
Write-Host "  Partial:           $PartialItems"
Write-Host "  Remaining:         $($result.RemainingItems)"
Write-Host "  Batch size:        $BatchSize (efficiency: $([Math]::Round($BatchEfficiency * 100))%)"
Write-Host "  Est. iterations:   $($result.TotalIterations) ($($result.BaseIterations) base + $($result.RetryIterations) retries)"
if ($autoDetected) {
    Write-Host "  Source:            blueprint.json (auto-detected)" -ForegroundColor DarkGreen
}
Write-Host ""

# Model Pricing
$pricingDateStr = if ($pricingData.lastUpdated -is [DateTime]) { $pricingData.lastUpdated.ToString("yyyy-MM-dd") } elseif ($pricingData.lastUpdated) { "$($pricingData.lastUpdated)".Substring(0,10) } else { "unknown" }
$pricingSource = if ($pricingData.source -and $pricingData.source -ne "hardcoded-fallback") { "live (cached $pricingDateStr)" } else { "hardcoded fallback" }
Write-Host "  MODEL PRICING (per 1M tokens) - source: $pricingSource" -ForegroundColor White
Write-Host "  -----------------------------------------------"
Write-Host ("  {0,-30} {1,10} {2,10}" -f "Model", "Input", "Output")
Write-Host ("  {0,-30} {1,10} {2,10}" -f "-----", "-----", "------")
Write-Host ("  {0,-30} {1,10} {2,10}" -f $claudePricing.Name, ("`${0:N2}" -f $claudePricing.InputPerM), ("`${0:N2}" -f $claudePricing.OutputPerM))
Write-Host ("  {0,-30} {1,10} {2,10}" -f $codexPricing.Name, ("`${0:N2}" -f $codexPricing.InputPerM), ("`${0:N2}" -f $codexPricing.OutputPerM))
Write-Host ("  {0,-30} {1,10} {2,10}" -f $geminiPricing.Name, ("`${0:N2}" -f $geminiPricing.InputPerM), ("`${0:N2}" -f $geminiPricing.OutputPerM))
Write-Host ""

# Phase Breakdown
Write-Host "  PHASE-BY-PHASE BREAKDOWN" -ForegroundColor White
Write-Host "  -----------------------------------------------"
Write-Host ("  {0,-14} {1,-8} {2,6} {3,12} {4,12} {5,10}" -f "Phase", "Agent", "Iters", "Input Tok", "Output Tok", "Cost")
Write-Host ("  {0,-14} {1,-8} {2,6} {3,12} {4,12} {5,10}" -f "-----", "-----", "-----", "---------", "----------", "----")
foreach ($pd in $result.PhaseDetails) {
    $color = switch ($pd.Agent) { "Claude" { "Cyan" } "Codex" { "Magenta" } "Gemini" { "Yellow" } default { "White" } }
    Write-Host ("  {0,-14} " -f $pd.Phase) -NoNewline
    Write-Host ("{0,-8} " -f $pd.Agent) -ForegroundColor $color -NoNewline
    Write-Host ("{0,6} {1,12} {2,12} {3,10}" -f $pd.Iterations, ("{0:N0}" -f $pd.InputTok), ("{0:N0}" -f $pd.OutputTok), ("`${0:N2}" -f $pd.Cost))
}
Write-Host ("  {0,-14} {1,-8} {2,6} {3,12} {4,12} {5,10}" -f "", "", "", "---------", "----------", "------")
Write-Host ("  {0,-14} {1,-8} {2,6} {3,12} {4,12} " -f "TOTAL", "", "", ("{0:N0}" -f $result.TotalInputTokens), ("{0:N0}" -f $result.TotalOutputTokens)) -NoNewline
Write-Host ("`${0:N2}" -f $result.TotalCost) -ForegroundColor Green
Write-Host ""

# Cost by Agent
Write-Host "  COST BY AGENT" -ForegroundColor White
Write-Host "  -----------------------------------------------"
$agents = @("Claude", "Codex", "Gemini")
foreach ($agent in $agents) {
    $agentCost = $result.CostByAgent[$agent]
    $agentPct = if ($result.TotalCost -gt 0) { [Math]::Round(($agentCost / $result.TotalCost) * 100, 1) } else { 0 }
    $inTok = $result.TokensByAgent[$agent].Input
    $outTok = $result.TokensByAgent[$agent].Output
    $color = switch ($agent) { "Claude" { "Cyan" } "Codex" { "Magenta" } "Gemini" { "Yellow" } }

    # Visual bar
    $barLen = [Math]::Max(1, [Math]::Floor($agentPct / 2.5))
    $bar = "#" * $barLen

    Write-Host ("  {0,-8} " -f $agent) -ForegroundColor $color -NoNewline
    Write-Host ("`${0,8:N2}  {1,5:N1}%  " -f $agentCost, $agentPct) -NoNewline
    Write-Host $bar -ForegroundColor $color
    Write-Host ("           Input: {0:N0} tokens  |  Output: {1:N0} tokens" -f $inTok, $outTok) -ForegroundColor DarkGray
}
Write-Host ""

# Key Metrics
$costPerPercent = if ((100 - $healthPct) -gt 0) { $result.TotalCost / (100 - $healthPct) } else { 0 }
$costPerItem = if ($result.RemainingItems -gt 0) { $result.TotalCost / $result.RemainingItems } else { 0 }
$costPerIter = if ($result.TotalIterations -gt 0) { $result.TotalCost / $result.TotalIterations } else { 0 }
$totalTokens = $result.TotalInputTokens + $result.TotalOutputTokens

Write-Host "  KEY METRICS" -ForegroundColor White
Write-Host "  -----------------------------------------------"
Write-Host ("  Total tokens:      {0:N0}" -f $totalTokens)
Write-Host ("  Total cost:        `${0:N2}" -f $result.TotalCost) -ForegroundColor Green
Write-Host ("  Cost per 1%:       `${0:N2}" -f $costPerPercent)
Write-Host ("  Cost per item:     `${0:N2}" -f $costPerItem)
Write-Host ("  Cost per iter:     `${0:N2}" -f $costPerIter)
Write-Host ("  Avg output/item:   {0:N0} tokens" -f $result.AvgOutputPerItem)
Write-Host ""

# Historical progression rate (if available)
if ($projectHealthHistory.Count -ge 2) {
    Write-Host "  HISTORICAL PROGRESSION (from health-history.jsonl)" -ForegroundColor White
    Write-Host "  -----------------------------------------------"
    $first = $projectHealthHistory[0]
    $last  = $projectHealthHistory[-1]
    $healthGain = $last.health - $first.health
    $itersUsed  = $last.iteration - $first.iteration
    $avgGainPerIter = if ($itersUsed -gt 0) { $healthGain / $itersUsed } else { 0 }
    $remainingHealth = 100 - $last.health
    $estimatedItersFromHistory = if ($avgGainPerIter -gt 0) { [Math]::Ceiling($remainingHealth / $avgGainPerIter) } else { "N/A" }

    Write-Host ("  Iterations so far: {0}" -f $itersUsed)
    Write-Host ("  Health gained:     {0:N1}% ({1:N1}% -> {2:N1}%)" -f $healthGain, $first.health, $last.health)
    Write-Host ("  Avg gain/iter:     {0:N1}%" -f $avgGainPerIter)
    Write-Host ("  Est. remaining:    $estimatedItersFromHistory iterations to 100%")

    # Recalculate cost using historical rate
    if ($estimatedItersFromHistory -ne "N/A" -and $estimatedItersFromHistory -gt 0) {
        $historicalCostMultiplier = $estimatedItersFromHistory / [Math]::Max(1, $result.TotalIterations)
        $adjustedCost = $result.TotalCost * $historicalCostMultiplier
        Write-Host ("  Adjusted cost:     `${0:N2} (based on actual progression)" -f $adjustedCost) -ForegroundColor Green
    }
    Write-Host ""
}

# ============================================================================
# PIPELINE COMPARISON (optional)
# ============================================================================

if ($ShowComparison) {
    $altPipeline = if ($Pipeline -eq "blueprint") { "convergence" } else { "blueprint" }

    $altResult = Get-PipelineCost `
        -PipelineType $altPipeline `
        -Total $TotalItems `
        -Completed $CompletedItems `
        -Partial $PartialItems `
        -Batch $BatchSize `
        -Efficiency $BatchEfficiency `
        -Retries $RetryRate `
        -ClaudePrices $claudePricing `
        -CodexPrices $codexPricing `
        -GeminiPrices $geminiPricing `
        -Items $blueprintItems

    Write-Host "  PIPELINE COMPARISON" -ForegroundColor White
    Write-Host "  -----------------------------------------------"
    Write-Host ("  {0,-25} {1,15} {2,15}" -f "", "BLUEPRINT", "CONVERGENCE")
    Write-Host ("  {0,-25} {1,15} {2,15}" -f "", "---------", "-----------")

    $bpResult  = if ($Pipeline -eq "blueprint") { $result } else { $altResult }
    $cvResult  = if ($Pipeline -eq "convergence") { $result } else { $altResult }

    Write-Host ("  {0,-25} {1,15} {2,15}" -f "Phases per iteration", "2 (verify+build)", "5 (full loop)")
    Write-Host ("  {0,-25} {1,15} {2,15}" -f "Estimated iterations", $bpResult.TotalIterations, $cvResult.TotalIterations)
    Write-Host ("  {0,-25} {1,15:N0} {2,15:N0}" -f "Total input tokens", $bpResult.TotalInputTokens, $cvResult.TotalInputTokens)
    Write-Host ("  {0,-25} {1,15:N0} {2,15:N0}" -f "Total output tokens", $bpResult.TotalOutputTokens, $cvResult.TotalOutputTokens)
    Write-Host ""
    Write-Host ("  {0,-25} " -f "Claude cost") -NoNewline
    Write-Host ("{0,15}" -f ("`${0:N2}" -f $bpResult.CostByAgent["Claude"])) -ForegroundColor Cyan -NoNewline
    Write-Host ("{0,15}" -f ("`${0:N2}" -f $cvResult.CostByAgent["Claude"])) -ForegroundColor Cyan
    Write-Host ("  {0,-25} " -f "Codex cost") -NoNewline
    Write-Host ("{0,15}" -f ("`${0:N2}" -f $bpResult.CostByAgent["Codex"])) -ForegroundColor Magenta -NoNewline
    Write-Host ("{0,15}" -f ("`${0:N2}" -f $cvResult.CostByAgent["Codex"])) -ForegroundColor Magenta
    Write-Host ("  {0,-25} " -f "Gemini cost") -NoNewline
    Write-Host ("{0,15}" -f ("`${0:N2}" -f $bpResult.CostByAgent["Gemini"])) -ForegroundColor Yellow -NoNewline
    Write-Host ("{0,15}" -f ("`${0:N2}" -f $cvResult.CostByAgent["Gemini"])) -ForegroundColor Yellow
    Write-Host ("  {0,-25} {1,15} {2,15}" -f "-----", "--------", "--------")
    Write-Host ("  {0,-25} " -f "TOTAL COST") -NoNewline
    Write-Host ("{0,15}" -f ("`${0:N2}" -f $bpResult.TotalCost)) -ForegroundColor Green -NoNewline
    Write-Host ("{0,15}" -f ("`${0:N2}" -f $cvResult.TotalCost)) -ForegroundColor Green
    Write-Host ""

    # Savings
    $savings = $cvResult.TotalCost - $bpResult.TotalCost
    $savingsPct = if ($cvResult.TotalCost -gt 0) { [Math]::Round(($savings / $cvResult.TotalCost) * 100, 1) } else { 0 }
    if ($savings -gt 0) {
        Write-Host ("  Blueprint saves `${0:N2} ({1}%) vs Convergence" -f $savings, $savingsPct) -ForegroundColor Green
    } else {
        Write-Host ("  Convergence saves `${0:N2} ({1}%) vs Blueprint" -f (-$savings), (-$savingsPct)) -ForegroundColor Green
    }
    Write-Host ""
}

# ============================================================================
# DETAILED PER-ITERATION VIEW (optional)
# ============================================================================

if ($Detailed) {
    Write-Host "  PER-ITERATION COST BREAKDOWN (first 10)" -ForegroundColor White
    Write-Host "  -----------------------------------------------"
    $showIters = [Math]::Min(10, $result.TotalIterations)
    $cumulativeCost = 0.0

    # Blueprint phase cost (one-time, iteration 0)
    $bpPhase = $result.PhaseDetails | Where-Object { $_.Phase -eq "Blueprint" }
    if ($bpPhase) {
        $cumulativeCost += $bpPhase.Cost
        Write-Host ("  Init     Blueprint (once)          `${0,8:N2}    cumulative: `${1:N2}" -f $bpPhase.Cost, $cumulativeCost)
    }

    for ($i = 1; $i -le $showIters; $i++) {
        $iterCost = 0.0
        foreach ($pd in ($result.PhaseDetails | Where-Object { $_.Phase -ne "Blueprint" })) {
            # Spread occasional phases across iterations
            $freq = $pd.Iterations / [Math]::Max(1, $result.TotalIterations)
            $iterCost += ($pd.Cost / [Math]::Max(1, $pd.Iterations)) * [Math]::Min(1.0, $freq)
        }
        $cumulativeCost += $iterCost
        $estHealth = [Math]::Min(100, $healthPct + ($i * ((100 - $healthPct) / $result.TotalIterations)))
        Write-Host ("  Iter {0,2}   health ~{1,5:N1}%              `${2,8:N2}    cumulative: `${3:N2}" -f $i, $estHealth, $iterCost, $cumulativeCost)
    }
    if ($result.TotalIterations -gt 10) {
        Write-Host "  ... ($($result.TotalIterations - 10) more iterations)"
    }
    Write-Host ("  -----------------------------------------------")
    Write-Host ("  FINAL    health  100.0%              `${0,8:N2}    TOTAL" -f $result.TotalCost) -ForegroundColor Green
    Write-Host ""
}

# ============================================================================
# SUBSCRIPTION CONTEXT
# ============================================================================

Write-Host "  SUBSCRIPTION NOTE" -ForegroundColor White
Write-Host "  -----------------------------------------------"
Write-Host "  These costs reflect equivalent API (pay-per-token) pricing."
Write-Host "  With subscriptions, actual costs depend on your plan limits:"
Write-Host "    Claude Pro:      `$20/mo  (limited messages)"
Write-Host "    Claude Max:      `$100-200/mo (higher limits)"
Write-Host "    ChatGPT Plus:    `$20/mo  (includes Codex CLI)"
Write-Host "    ChatGPT Pro:     `$200/mo (unlimited GPT-4/Codex)"
Write-Host "    Gemini Advanced: `$20/mo  (Gemini 3.1 Pro access)"
Write-Host ""
Write-Host "  If your project needs $($result.TotalIterations) iterations, subscription"
Write-Host "  cost depends on how many iterations fit within monthly limits."
Write-Host ""

# Subscription estimate
$monthlySubCost = 20 + 20 + 20  # Claude Pro + ChatGPT Plus + Gemini Advanced (minimum)
$itersPerDay = 3  # Rough estimate based on throttling + quota
$daysToComplete = [Math]::Ceiling($result.TotalIterations / $itersPerDay)
$monthsToComplete = [Math]::Ceiling($daysToComplete / 30)
$subTotalCost = $monthsToComplete * $monthlySubCost

Write-Host "  SUBSCRIPTION ESTIMATE (at ~$itersPerDay iterations/day)" -ForegroundColor White
Write-Host "  -----------------------------------------------"
Write-Host ("  Days to complete:    ~{0} days" -f $daysToComplete)
Write-Host ("  Months:              ~{0} month(s)" -f $monthsToComplete)
Write-Host ("  Min sub cost:        `${0}/mo (Pro tiers: Claude+ChatGPT+Gemini)" -f $monthlySubCost)
Write-Host ("  Total sub cost:      `${0:N0}" -f $subTotalCost) -ForegroundColor Yellow
Write-Host ("  vs API cost:         `${0:N2}" -f $result.TotalCost) -ForegroundColor Green
if ($subTotalCost -lt $result.TotalCost) {
    $subSavings = $result.TotalCost - $subTotalCost
    Write-Host ("  Subscription saves:  `${0:N2} ({1:N0}%)" -f $subSavings, (($subSavings / $result.TotalCost) * 100)) -ForegroundColor Green
} else {
    $apiSavings = $subTotalCost - $result.TotalCost
    Write-Host ("  API saves:           `${0:N2} ({1:N0}%)" -f $apiSavings, (($apiSavings / $subTotalCost) * 100)) -ForegroundColor Green
}
Write-Host ""

# ============================================================================
# CLIENT QUOTE (optional)
# ============================================================================

if ($ClientQuote) {
    $baseCost       = $result.TotalCost
    $quotedCost     = [Math]::Round($baseCost * $Markup, 2)
    $quoteDate      = (Get-Date).ToString("MMMM d, yyyy")
    $quoteRef       = "GSD-" + (Get-Date).ToString("yyyyMMdd") + "-" + $TotalItems

    # Complexity tier based on items + pipeline
    $complexityTier = if ($TotalItems -le 100) { "Standard" }
                      elseif ($TotalItems -le 250) { "Complex" }
                      elseif ($TotalItems -le 500) { "Enterprise" }
                      else { "Enterprise+" }

    # Estimated timeline
    $estWeeks = [Math]::Ceiling($daysToComplete / 7)
    $estWeeksHigh = [Math]::Ceiling($estWeeks * 1.5)

    # Tier breakdown for the quote (low / expected / high)
    $quoteLow      = [Math]::Round($baseCost * ($Markup * 0.6), 2)
    $quoteExpected  = $quotedCost
    $quoteHigh      = [Math]::Round($baseCost * ($Markup * 1.4), 2)

    Write-Host ""
    Write-Host "============================================================================" -ForegroundColor Green
    Write-Host "  CLIENT QUOTE - AI Development Cost Estimate                               " -ForegroundColor Green
    Write-Host "============================================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Quote Reference:   $quoteRef"
    Write-Host "  Date:              $quoteDate"
    Write-Host "  Project:           $ClientName" -ForegroundColor White
    Write-Host "  Complexity:        $complexityTier ($TotalItems deliverables)" -ForegroundColor White
    Write-Host ""
    Write-Host "  -----------------------------------------------"
    Write-Host "  SCOPE" -ForegroundColor White
    Write-Host "  -----------------------------------------------"
    Write-Host "  Total deliverables:   $TotalItems files/components"
    if ($CompletedItems -gt 0) {
        Write-Host "  Already completed:    $CompletedItems ($healthPct%)"
        Write-Host "  Remaining scope:      $($result.RemainingItems) deliverables"
    }
    Write-Host "  Pipeline:             $($Pipeline.ToUpper()) (autonomous AI development)"
    Write-Host "  AI Models:            Claude + Codex + Gemini (3-model strategy)"
    Write-Host ""
    Write-Host "  -----------------------------------------------"
    Write-Host "  ESTIMATED COST" -ForegroundColor White
    Write-Host "  -----------------------------------------------"
    Write-Host ""
    Write-Host ("  Best case:            `${0:N2}" -f $quoteLow) -ForegroundColor DarkGray
    Write-Host ("  Expected:             `${0:N2}" -f $quoteExpected) -ForegroundColor Green
    Write-Host ("  Worst case:           `${0:N2}" -f $quoteHigh) -ForegroundColor Yellow
    Write-Host ""
    Write-Host ("  (Based on {0}x markup over estimated AI compute cost of `${1:N2})" -f $Markup, $baseCost) -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  -----------------------------------------------"
    Write-Host "  ESTIMATED TIMELINE" -ForegroundColor White
    Write-Host "  -----------------------------------------------"
    Write-Host ("  Iterations needed:    ~{0}" -f $result.TotalIterations)
    Write-Host ("  Estimated duration:   {0}-{1} weeks" -f $estWeeks, $estWeeksHigh)
    Write-Host ""
    Write-Host "  -----------------------------------------------"
    Write-Host "  WHAT'S INCLUDED" -ForegroundColor White
    Write-Host "  -----------------------------------------------"

    # Dynamic inclusions based on pipeline
    $inclusions = @(
        "AI-generated production-ready code ($TotalItems deliverables)"
        "Automated build verification (dotnet build + npm build)"
        "Iterative quality convergence to 100% health score"
        "Blueprint architecture manifest with acceptance criteria"
    )
    if ($Pipeline -eq "convergence") {
        $inclusions += "AI-powered code review each iteration"
        $inclusions += "Automated pattern research and optimization"
    }
    $inclusions += "Spec conflict detection and auto-resolution"
    $inclusions += "Git version control with per-iteration commits"

    foreach ($inc in $inclusions) {
        Write-Host "    - $inc"
    }
    Write-Host ""
    Write-Host "  -----------------------------------------------"
    Write-Host "  NOTES" -ForegroundColor White
    Write-Host "  -----------------------------------------------"
    Write-Host "    - Cost covers AI compute for autonomous code generation"
    Write-Host "    - Human review, testing, and deployment are separate"
    Write-Host "    - Estimate assumes specs and design are finalized"
    Write-Host "    - Scope changes may adjust the estimate"
    Write-Host "    - Quote valid for 30 days from date above"
    Write-Host ""
    Write-Host "============================================================================" -ForegroundColor Green
    Write-Host ""

    # Margin analysis (internal - not for client)
    Write-Host "  INTERNAL: MARGIN ANALYSIS (not for client)" -ForegroundColor DarkRed
    Write-Host "  -----------------------------------------------" -ForegroundColor DarkGray
    Write-Host ("  Raw AI compute cost:  `${0:N2}" -f $baseCost) -ForegroundColor DarkGray
    Write-Host ("  Markup applied:       {0}x" -f $Markup) -ForegroundColor DarkGray
    Write-Host ("  Client quote:         `${0:N2}" -f $quoteExpected) -ForegroundColor DarkGray
    Write-Host ("  Gross margin:         `${0:N2} ({1:N0}%)" -f ($quoteExpected - $baseCost), ((1 - (1 / $Markup)) * 100)) -ForegroundColor DarkGray
    $subCostForProject = $monthsToComplete * $monthlySubCost
    Write-Host ("  Your actual cost:     ~`${0:N0} (subscriptions for {1}mo)" -f $subCostForProject, $monthsToComplete) -ForegroundColor DarkGray
    Write-Host ("  True profit:          ~`${0:N2}" -f ($quoteExpected - $subCostForProject)) -ForegroundColor DarkGray
    Write-Host ("  True margin:          ~{0:N0}%" -f ((($quoteExpected - $subCostForProject) / $quoteExpected) * 100)) -ForegroundColor DarkGray
    Write-Host ""
}

# ============================================================================
# ACTUAL COST TRACKING
# ============================================================================

if ($ShowActual) {
    # Resolve project path for cost data
    $actualProjectPath = if ($ProjectPath) { $ProjectPath } else { (Get-Location).Path }
    $costSummaryPath = Join-Path $actualProjectPath ".gsd\costs\cost-summary.json"

    if (Test-Path $costSummaryPath) {
        try {
            $actual = Get-Content $costSummaryPath -Raw | ConvertFrom-Json

            Write-Host ""
            Write-Host "============================================================================" -ForegroundColor Magenta
            Write-Host "  ACTUAL TOKEN COSTS (from pipeline runs)" -ForegroundColor Magenta
            Write-Host "============================================================================" -ForegroundColor Magenta
            Write-Host ""
            Write-Host "  SUMMARY" -ForegroundColor White
            Write-Host "  -----------------------------------------------"
            Write-Host ("  Total agent calls:    {0}" -f $actual.total_calls)
            Write-Host ("  Total cost:           `${0:N4}" -f $actual.total_cost_usd) -ForegroundColor Green
            if ($actual.total_tokens) {
                $totalTokens = [long]$actual.total_tokens.input + [long]$actual.total_tokens.output
                Write-Host ("  Total tokens:         {0:N0} ({1:N0} in / {2:N0} out)" -f $totalTokens, $actual.total_tokens.input, $actual.total_tokens.output)
                if ($actual.total_tokens.cached -gt 0) {
                    Write-Host ("  Cached tokens:        {0:N0}" -f $actual.total_tokens.cached)
                }
            }
            Write-Host ("  First run:            {0}" -f $actual.project_start)
            Write-Host ("  Last updated:         {0}" -f $actual.last_updated)
            Write-Host ""

            # Cost by agent with bar chart
            if ($actual.by_agent) {
                Write-Host "  ACTUAL COST BY AGENT" -ForegroundColor White
                Write-Host "  -----------------------------------------------"
                $agents = @($actual.by_agent.PSObject.Properties)
                $maxCost = ($agents | ForEach-Object { [double]$_.Value.cost_usd } | Measure-Object -Maximum).Maximum
                if ($maxCost -eq 0) { $maxCost = 1 }

                foreach ($agentProp in $agents) {
                    $agentName = $agentProp.Name
                    $agentData = $agentProp.Value
                    $cost = [double]$agentData.cost_usd
                    $pct = if ($actual.total_cost_usd -gt 0) { ($cost / $actual.total_cost_usd) * 100 } else { 0 }
                    $barLen = [math]::Max(1, [math]::Floor(($cost / $maxCost) * 25))
                    $bar = "#" * $barLen
                    $label = "{0,-8} `${1:N4}  {2,5:N1}%  {3}" -f $agentName, $cost, $pct, $bar
                    Write-Host "  $label"
                    if ($agentData.tokens) {
                        Write-Host ("            In: {0:N0}  |  Out: {1:N0}  |  Calls: {2}" -f `
                            $agentData.tokens.input, $agentData.tokens.output, $agentData.calls) -ForegroundColor DarkGray
                    }
                }
                Write-Host ""
            }

            # Cost by phase
            if ($actual.by_phase) {
                Write-Host "  ACTUAL COST BY PHASE" -ForegroundColor White
                Write-Host "  -----------------------------------------------"
                $phases = @($actual.by_phase.PSObject.Properties)
                foreach ($phaseProp in $phases) {
                    $phaseName = $phaseProp.Name
                    $phaseData = $phaseProp.Value
                    $cost = [double]$phaseData.cost_usd
                    $pct = if ($actual.total_cost_usd -gt 0) { ($cost / $actual.total_cost_usd) * 100 } else { 0 }
                    Write-Host ("  {0,-16} `${1:N4}  ({2:N1}%)  [{3} calls]" -f $phaseName, $cost, $pct, $phaseData.calls)
                }
                Write-Host ""
            }

            # Run history
            if ($actual.runs -and $actual.runs.Count -gt 0) {
                Write-Host "  RUN HISTORY" -ForegroundColor White
                Write-Host "  -----------------------------------------------"
                for ($r = 0; $r -lt $actual.runs.Count; $r++) {
                    $run = $actual.runs[$r]
                    $endStr = if ($run.ended) { $run.ended.Substring(0, 19) } else { "(running)" }
                    $startStr = if ($run.started) { $run.started.Substring(0, 19) } else { "?" }
                    Write-Host ("  Run {0}: {1} -> {2}  |  {3} calls  |  `${4:N4}" -f ($r + 1), $startStr, $endStr, $run.calls, $run.cost_usd)
                }
                Write-Host ""
            }

            # Estimated vs actual comparison (if estimates are available)
            if ($result -and $result.TotalCost -gt 0) {
                Write-Host "  ESTIMATED VS ACTUAL" -ForegroundColor Yellow
                Write-Host "  -----------------------------------------------"
                $estTotal = $result.TotalCost
                $actTotal = [double]$actual.total_cost_usd
                $variance = if ($estTotal -gt 0) { (($actTotal - $estTotal) / $estTotal) * 100 } else { 0 }
                $varStr = if ($variance -ge 0) { "+{0:N1}%" -f $variance } else { "{0:N1}%" -f $variance }
                Write-Host ("  {0,-20} {1,12} {2,12} {3,10}" -f "", "Estimated", "Actual", "Variance") -ForegroundColor DarkGray
                Write-Host ("  {0,-20} `${1,10:N4} `${2,10:N4} {3,10}" -f "Total cost", $estTotal, $actTotal, $varStr)

                # Per-agent comparison
                if ($result.Costs -and $actual.by_agent) {
                    foreach ($agentName in @("claude", "codex", "gemini")) {
                        $estCost = if ($result.Costs.$agentName) { [double]$result.Costs.$agentName } else { 0 }
                        $actCost = 0
                        if ($actual.by_agent.PSObject.Properties[$agentName]) {
                            $actCost = [double]$actual.by_agent.$agentName.cost_usd
                        }
                        if ($estCost -gt 0 -or $actCost -gt 0) {
                            $v = if ($estCost -gt 0) { (($actCost - $estCost) / $estCost) * 100 } else { 0 }
                            $vs = if ($v -ge 0) { "+{0:N1}%" -f $v } else { "{0:N1}%" -f $v }
                            Write-Host ("  {0,-20} `${1,10:N4} `${2,10:N4} {3,10}" -f $agentName, $estCost, $actCost, $vs)
                        }
                    }
                }
                Write-Host ""

                # Actual cost efficiency
                Write-Host "  ACTUAL COST EFFICIENCY" -ForegroundColor White
                Write-Host "  -----------------------------------------------"
                if ($actual.total_calls -gt 0) {
                    Write-Host ("  `$/agent call:     `${0:N4}" -f ($actTotal / $actual.total_calls))
                }

                # Estimate remaining cost at actual rate
                $healthPath = Join-Path $actualProjectPath ".gsd\health\health-current.json"
                if (Test-Path $healthPath) {
                    try {
                        $health = Get-Content $healthPath -Raw | ConvertFrom-Json
                        $currentHealth = [double]$health.health_score
                        if ($currentHealth -gt 0 -and $currentHealth -lt 100) {
                            $costPerPct = $actTotal / $currentHealth
                            $remaining = (100 - $currentHealth) * $costPerPct
                            Write-Host ("  `$/1%% health:      `${0:N4}" -f $costPerPct)
                            Write-Host ("  Remaining est:    ~`${0:N2} to reach 100%% (at actual rate)" -f $remaining) -ForegroundColor Yellow
                        }
                    } catch { }
                }
                Write-Host ""
            }
        } catch {
            Write-Host "  [!!] Error reading cost data: $($_.Exception.Message)" -ForegroundColor Red
        }
    } else {
        Write-Host ""
        Write-Host "  No actual cost data found at: $costSummaryPath" -ForegroundColor DarkYellow
        Write-Host "  Run a pipeline (gsd-converge or gsd-blueprint) to start tracking costs." -ForegroundColor DarkGray
        Write-Host ""
    }
}

Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "  Pricing source: $pricingSource" -ForegroundColor DarkGray
Write-Host "  Run -UpdatePricing to fetch latest prices from provider websites." -ForegroundColor DarkGray
Write-Host "  Run -ShowComparison for blueprint vs convergence cost comparison." -ForegroundColor DarkGray
Write-Host "  Run -ShowActual to see actual costs from pipeline runs." -ForegroundColor DarkGray
Write-Host "  Run -Detailed for per-iteration breakdown." -ForegroundColor DarkGray
Write-Host "  Run -ClaudeModel opus|haiku to compare Claude model costs." -ForegroundColor DarkGray
Write-Host "  Run -ClientQuote -Markup 7 -ClientName 'Acme' for client estimate." -ForegroundColor DarkGray
Write-Host "  Cache: $PricingCachePath" -ForegroundColor DarkGray
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host ""
