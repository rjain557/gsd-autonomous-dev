<#
.SYNOPSIS
    Agent Intelligence - Performance scoring and warm-start for new projects.
    Run AFTER patch-gsd-speed-optimizations.ps1.

.DESCRIPTION
    Adds two intelligence features:

    1. Agent Performance Scoring (Rec #19):
       - Tracks requirements_satisfied_per_token by agent
       - Tracks rework_rate (satisfied -> partial regression) by agent
       - Scores agents on cost-effectiveness and reliability
       - Data-driven agent routing recommendations
       - Stored in .gsd/intelligence/agent-scores.json

    2. Warm-Start for New Projects (Rec #20):
       - Caches successful code patterns by project type
       - Pre-populates create-phases with known requirement templates
       - Shares detected-patterns.json across similar projects
       - Global pattern cache: ~/.gsd-global/intelligence/pattern-cache.json

    Config: agent_intelligence block in global-config.json

.INSTALL_ORDER
    1-29. (existing scripts)
    30. patch-gsd-agent-intelligence.ps1  <- this file
#>

param([string]$UserHome = $env:USERPROFILE)
$ErrorActionPreference = "Stop"

$GsdGlobalDir = Join-Path $UserHome ".gsd-global"

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  GSD Agent Intelligence (Scoring + Warm-Start)" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

# ── 1. Add agent_intelligence config ──

$configPath = Join-Path $GsdGlobalDir "config\global-config.json"
if (Test-Path $configPath) {
    $config = Get-Content $configPath -Raw | ConvertFrom-Json

    if (-not $config.agent_intelligence) {
        $config | Add-Member -NotePropertyName "agent_intelligence" -NotePropertyValue ([PSCustomObject]@{
            performance_scoring = ([PSCustomObject]@{
                enabled              = $true
                min_samples          = 3
                recalculate_interval = 5
            })
            warm_start = ([PSCustomObject]@{
                enabled           = $true
                cache_patterns    = $true
                share_across_projects = $true
                project_types     = @("dotnet-react", "dotnet-api", "react-spa", "fullstack")
            })
        })
        $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath -Encoding UTF8
        Write-Host "  [OK] Added agent_intelligence config" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] agent_intelligence already exists" -ForegroundColor DarkGray
    }
}

# ── 2. Create intelligence directory ──

$intelligenceDir = Join-Path $GsdGlobalDir "intelligence"
if (-not (Test-Path $intelligenceDir)) {
    New-Item -Path $intelligenceDir -ItemType Directory -Force | Out-Null
    Write-Host "  [OK] Created intelligence directory" -ForegroundColor Green
}

# ── 3. Add agent intelligence functions to resilience.ps1 ──

$resilienceFile = Join-Path $GsdGlobalDir "lib\modules\resilience.ps1"
if (Test-Path $resilienceFile) {
    $existing = Get-Content $resilienceFile -Raw

    if ($existing -notlike "*function Update-AgentPerformanceScore*") {

        $intelligenceFunctions = @'

# ===========================================
# AGENT INTELLIGENCE
# ===========================================

# ── Agent Performance Scoring ──

function Update-AgentPerformanceScore {
    param(
        [string]$GsdDir,
        [string]$GlobalDir,
        [string]$Agent,
        [string]$Phase,
        [int]$TokensUsed,
        [int]$RequirementsSatisfied,
        [int]$RequirementsRegressed,
        [int]$Iteration
    )

    # Check config
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            if (-not $config.agent_intelligence -or -not $config.agent_intelligence.performance_scoring -or
                -not $config.agent_intelligence.performance_scoring.enabled) { return }
        } catch { return }
    } else { return }

    # Load or create scores
    $scoresDir = Join-Path $GsdDir "intelligence"
    if (-not (Test-Path $scoresDir)) {
        New-Item -Path $scoresDir -ItemType Directory -Force | Out-Null
    }
    $scoresPath = Join-Path $scoresDir "agent-scores.json"

    $scores = @{}
    if (Test-Path $scoresPath) {
        try { $scores = Get-Content $scoresPath -Raw | ConvertFrom-Json -AsHashtable } catch { $scores = @{} }
    }

    # Initialize agent entry if missing
    if (-not $scores.ContainsKey($Agent)) {
        $scores[$Agent] = @{
            total_tokens             = 0
            total_requirements_done  = 0
            total_regressions        = 0
            samples                  = 0
            efficiency_score         = 0.0
            reliability_score        = 0.0
            overall_score            = 0.0
            history                  = @()
        }
    }

    $agentData = $scores[$Agent]
    $agentData.total_tokens += $TokensUsed
    $agentData.total_requirements_done += $RequirementsSatisfied
    $agentData.total_regressions += $RequirementsRegressed
    $agentData.samples += 1

    # Record history entry
    $agentData.history += @{
        iteration    = $Iteration
        phase        = $Phase
        tokens       = $TokensUsed
        satisfied    = $RequirementsSatisfied
        regressed    = $RequirementsRegressed
        timestamp    = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }

    # Keep last 50 entries
    if ($agentData.history.Count -gt 50) {
        $agentData.history = $agentData.history | Select-Object -Last 50
    }

    # Calculate scores
    if ($agentData.total_tokens -gt 0) {
        # Efficiency: requirements satisfied per 1000 tokens
        $agentData.efficiency_score = [math]::Round(($agentData.total_requirements_done / ($agentData.total_tokens / 1000)), 3)
    }

    if ($agentData.total_requirements_done -gt 0) {
        # Reliability: 1 - (regressions / total done)
        $agentData.reliability_score = [math]::Round(1 - ($agentData.total_regressions / $agentData.total_requirements_done), 3)
    } else {
        $agentData.reliability_score = 0
    }

    # Overall: weighted average (60% reliability, 40% efficiency normalized)
    $agentData.overall_score = [math]::Round(($agentData.reliability_score * 0.6) + ([math]::Min(1.0, $agentData.efficiency_score) * 0.4), 3)

    $scores[$Agent] = $agentData
    $scores | ConvertTo-Json -Depth 10 | Set-Content -Path $scoresPath -Encoding UTF8

    # Also update global intelligence
    $globalScoresDir = Join-Path $GlobalDir "intelligence"
    if (-not (Test-Path $globalScoresDir)) {
        New-Item -Path $globalScoresDir -ItemType Directory -Force | Out-Null
    }
    $globalScoresPath = Join-Path $globalScoresDir "agent-scores-global.json"

    $globalScores = @{}
    if (Test-Path $globalScoresPath) {
        try { $globalScores = Get-Content $globalScoresPath -Raw | ConvertFrom-Json -AsHashtable } catch { $globalScores = @{} }
    }

    if (-not $globalScores.ContainsKey($Agent)) {
        $globalScores[$Agent] = @{
            total_tokens = 0; total_requirements_done = 0; total_regressions = 0; samples = 0;
            efficiency_score = 0.0; reliability_score = 0.0; overall_score = 0.0;
            projects = @()
        }
    }

    $globalData = $globalScores[$Agent]
    $globalData.total_tokens += $TokensUsed
    $globalData.total_requirements_done += $RequirementsSatisfied
    $globalData.total_regressions += $RequirementsRegressed
    $globalData.samples += 1

    if ($globalData.total_tokens -gt 0) {
        $globalData.efficiency_score = [math]::Round(($globalData.total_requirements_done / ($globalData.total_tokens / 1000)), 3)
    }
    if ($globalData.total_requirements_done -gt 0) {
        $globalData.reliability_score = [math]::Round(1 - ($globalData.total_regressions / $globalData.total_requirements_done), 3)
    }
    $globalData.overall_score = [math]::Round(($globalData.reliability_score * 0.6) + ([math]::Min(1.0, $globalData.efficiency_score) * 0.4), 3)

    $globalScores[$Agent] = $globalData
    $globalScores | ConvertTo-Json -Depth 10 | Set-Content -Path $globalScoresPath -Encoding UTF8
}

function Get-BestAgentForPhase {
    param(
        [string]$GsdDir,
        [string]$GlobalDir,
        [string]$Phase,
        [string]$DefaultAgent
    )

    $scoresPath = Join-Path $GsdDir "intelligence\agent-scores.json"
    if (-not (Test-Path $scoresPath)) { return $DefaultAgent }

    try {
        $scores = Get-Content $scoresPath -Raw | ConvertFrom-Json -AsHashtable
    } catch { return $DefaultAgent }

    # Check config for min samples
    $minSamples = 3
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            if ($config.agent_intelligence.performance_scoring.min_samples) {
                $minSamples = [int]$config.agent_intelligence.performance_scoring.min_samples
            }
        } catch {}
    }

    # Find best agent for this phase
    $bestAgent = $DefaultAgent
    $bestScore = -1

    foreach ($kvp in $scores.GetEnumerator()) {
        $agent = $kvp.Key
        $data = $kvp.Value
        if ($data.samples -ge $minSamples -and $data.overall_score -gt $bestScore) {
            # Check if this agent has history for the requested phase
            $phaseHistory = $data.history | Where-Object { $_.phase -eq $Phase }
            if ($phaseHistory.Count -ge $minSamples) {
                $bestScore = $data.overall_score
                $bestAgent = $agent
            }
        }
    }

    if ($bestAgent -ne $DefaultAgent) {
        Write-Host "  [INTELLIGENCE] Agent recommendation for $Phase`: $bestAgent (score: $bestScore) vs default: $DefaultAgent" -ForegroundColor Cyan
    }

    return $bestAgent
}

# ── Warm-Start Pattern Cache ──

function Save-ProjectPatterns {
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [string]$GlobalDir
    )

    # Check config
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            if (-not $config.agent_intelligence -or -not $config.agent_intelligence.warm_start -or
                -not $config.agent_intelligence.warm_start.enabled) { return }
        } catch { return }
    } else { return }

    # Detect project type
    $projectType = "unknown"
    $hasDotnet = (Get-ChildItem -Path $RepoRoot -Filter "*.sln" -ErrorAction SilentlyContinue).Count -gt 0
    $hasReact = $false
    $pkgJson = Join-Path $RepoRoot "package.json"
    if (Test-Path $pkgJson) {
        $pkg = Get-Content $pkgJson -Raw -ErrorAction SilentlyContinue
        $hasReact = $pkg -match '"react"'
    }

    if ($hasDotnet -and $hasReact) { $projectType = "dotnet-react" }
    elseif ($hasDotnet) { $projectType = "dotnet-api" }
    elseif ($hasReact) { $projectType = "react-spa" }

    # Save patterns to global cache
    $cacheDir = Join-Path $GlobalDir "intelligence"
    if (-not (Test-Path $cacheDir)) {
        New-Item -Path $cacheDir -ItemType Directory -Force | Out-Null
    }

    $cachePath = Join-Path $cacheDir "pattern-cache.json"
    $cache = @{}
    if (Test-Path $cachePath) {
        try { $cache = Get-Content $cachePath -Raw | ConvertFrom-Json -AsHashtable } catch { $cache = @{} }
    }

    # Save detected patterns
    $patternsPath = Join-Path $GsdDir "assessment\detected-patterns.json"
    if (Test-Path $patternsPath) {
        $patterns = Get-Content $patternsPath -Raw

        if (-not $cache.ContainsKey($projectType)) {
            $cache[$projectType] = @{
                patterns = @()
                last_updated = ""
            }
        }

        $repoName = Split-Path $RepoRoot -Leaf
        $entry = @{
            repo     = $repoName
            patterns = $patterns
            saved    = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        }

        # Update or add
        $existingIdx = -1
        for ($i = 0; $i -lt $cache[$projectType].patterns.Count; $i++) {
            if ($cache[$projectType].patterns[$i].repo -eq $repoName) {
                $existingIdx = $i; break
            }
        }

        if ($existingIdx -ge 0) {
            $cache[$projectType].patterns[$existingIdx] = $entry
        } else {
            $cache[$projectType].patterns += $entry
        }

        $cache[$projectType].last_updated = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")

        $cache | ConvertTo-Json -Depth 10 | Set-Content -Path $cachePath -Encoding UTF8
        Write-Host "  [WARM] Saved project patterns to global cache (type: $projectType)" -ForegroundColor Green
    }
}

function Get-WarmStartPatterns {
    param(
        [string]$RepoRoot,
        [string]$GlobalDir
    )

    # Check config
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            if (-not $config.agent_intelligence -or -not $config.agent_intelligence.warm_start -or
                -not $config.agent_intelligence.warm_start.enabled) { return $null }
        } catch { return $null }
    } else { return $null }

    # Detect project type
    $projectType = "unknown"
    $hasDotnet = (Get-ChildItem -Path $RepoRoot -Filter "*.sln" -ErrorAction SilentlyContinue).Count -gt 0
    $hasReact = $false
    $pkgJson = Join-Path $RepoRoot "package.json"
    if (Test-Path $pkgJson) {
        $pkg = Get-Content $pkgJson -Raw -ErrorAction SilentlyContinue
        $hasReact = $pkg -match '"react"'
    }

    if ($hasDotnet -and $hasReact) { $projectType = "dotnet-react" }
    elseif ($hasDotnet) { $projectType = "dotnet-api" }
    elseif ($hasReact) { $projectType = "react-spa" }

    # Load global pattern cache
    $cachePath = Join-Path $GlobalDir "intelligence\pattern-cache.json"
    if (-not (Test-Path $cachePath)) { return $null }

    try {
        $cache = Get-Content $cachePath -Raw | ConvertFrom-Json -AsHashtable
    } catch { return $null }

    if ($cache.ContainsKey($projectType) -and $cache[$projectType].patterns.Count -gt 0) {
        $latest = $cache[$projectType].patterns | Select-Object -Last 1
        Write-Host "  [WARM] Loaded warm-start patterns for $projectType (from: $($latest.repo))" -ForegroundColor Green
        return $latest.patterns
    }

    return $null
}
'@

        Add-Content -Path $resilienceFile -Value $intelligenceFunctions -Encoding UTF8
        Write-Host "  [OK] Added agent intelligence functions to resilience.ps1" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] Agent intelligence functions already exist" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "  [INTELLIGENCE] Installation complete." -ForegroundColor Green
Write-Host "  Config: global-config.json -> agent_intelligence" -ForegroundColor DarkGray
Write-Host "  Functions: Update-AgentPerformanceScore, Get-BestAgentForPhase, Save-ProjectPatterns, Get-WarmStartPatterns" -ForegroundColor DarkGray
Write-Host "  Output: .gsd/intelligence/agent-scores.json, ~/.gsd-global/intelligence/pattern-cache.json" -ForegroundColor DarkGray
Write-Host ""
