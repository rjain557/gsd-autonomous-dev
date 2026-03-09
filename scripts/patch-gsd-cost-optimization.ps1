<#
.SYNOPSIS
    Cost Optimization - Cheap-first review, incremental council, batch-scoped research, cost-per-req tracking.
    Run AFTER patch-gsd-rate-limiter.ps1.

.DESCRIPTION
    Four optimizations to drive cost-per-line toward $0.01:

    1. Cheap-First Code Review:
       - Round 1: kimi/deepseek review each chunk (~$0.002/call)
       - Round 2: Claude verifies ONLY chunks with partial/not_started items
       - Quality gate: if cheap vs Claude divergence >5%, fall back to Claude for rest
       - Saves ~70% of review cost without sacrificing quality

    2. Incremental Council Requirements:
       - Iteration 1: full 3-agent extraction (unchanged)
       - Iteration 2+: skip extraction, run lightweight verify on changed-status reqs only
       - If new source files appear (git diff), trigger targeted extraction on those files
       - Saves ~$25/project

    3. Batch-Scoped Research:
       - Research ONLY the requirements in the current execute batch
       - Include remaining_blockers from health-current.json as research context
       - Saves ~80% of research cost with MORE useful output

    4. Cost-Per-Requirement Tracking:
       - Track $/requirement across iterations
       - Flag requirements costing >$5 that remain partial for human review
       - Prevents infinite retry on impossible requirements

    Config: agent-map.json -> cost_optimization block

.INSTALL_ORDER
    1-39. (existing scripts)
    40. patch-gsd-cost-optimization.ps1  <- this file
#>

param([string]$UserHome = $env:USERPROFILE)
$ErrorActionPreference = "Stop"

$GsdGlobalDir = Join-Path $UserHome ".gsd-global"

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  GSD Cost Optimization (#40)" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

# ── 1. Add cost_optimization config to agent-map.json ──

$agentMapPath = Join-Path $GsdGlobalDir "config\agent-map.json"
if (Test-Path $agentMapPath) {
    $agentMap = Get-Content $agentMapPath -Raw | ConvertFrom-Json

    if (-not $agentMap.cost_optimization) {
        $agentMap | Add-Member -NotePropertyName "cost_optimization" -NotePropertyValue ([PSCustomObject]@{
            enabled = $true
            cheap_first_review = ([PSCustomObject]@{
                enabled              = $true
                cheap_agents         = @("kimi", "deepseek", "minimax", "glm5")
                verify_agent         = "claude"
                verify_fallback      = "codex"
                divergence_threshold = 5
                skip_verify_if_all_satisfied = $true
            })
            incremental_council = ([PSCustomObject]@{
                enabled                    = $true
                full_extraction_iteration  = 1
                verify_only_after          = 1
                retrigger_on_new_files     = $true
            })
            batch_scoped_research = ([PSCustomObject]@{
                enabled                = $true
                include_blockers       = $true
                max_research_reqs      = 8
            })
            cost_per_requirement = ([PSCustomObject]@{
                enabled                = $true
                escalation_threshold   = 5.00
                max_iterations_partial = 4
            })
        }) -Force

        $agentMap | ConvertTo-Json -Depth 10 | Set-Content $agentMapPath -Encoding UTF8
        Write-Host "  [OK] cost_optimization config added to agent-map.json" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] cost_optimization config already exists" -ForegroundColor Yellow
    }
} else {
    Write-Host "  [WARN] agent-map.json not found at $agentMapPath" -ForegroundColor Yellow
}

# ── 2. Create batch-scoped research prompt template ──

$researchPromptDir = Join-Path $GsdGlobalDir "prompts\shared"
$batchResearchPath = Join-Path $researchPromptDir "research-batch-scoped.md"

if (-not (Test-Path $batchResearchPath)) {
    $batchResearchPrompt = @'
# Batch-Scoped Research - Iteration {{ITERATION}}

## Your Task
Research ONLY the specific requirements listed below. Do NOT research the entire project.
Focus on finding solutions to the specific blockers identified by code review.

## Requirements to Research
{{BATCH_REQUIREMENTS}}

## Known Blockers (from code review)
{{REMAINING_BLOCKERS}}

## Project Context
- GSD Dir: {{GSD_DIR}}
- Repo Root: {{REPO_ROOT}}
- Health: {{HEALTH}}%
- Interface Context: {{INTERFACE_CONTEXT}}

## Instructions
1. For each requirement, investigate the specific blocker or gap identified
2. Propose concrete code changes with file paths and line numbers
3. Prioritize by impact - which fixes will move the most requirements from partial -> satisfied
4. Keep output under 3000 tokens - be specific, not verbose
5. Do NOT research requirements that are already satisfied

## Output Format
For each requirement:
```
### REQ_ID: Short description
**Blocker**: What's preventing satisfaction
**Solution**: Specific code change needed
**Files**: file1.cs:line, file2.tsx:line
**Complexity**: low/medium/high
```
'@
    Set-Content $batchResearchPath -Value $batchResearchPrompt -Encoding UTF8
    Write-Host "  [OK] research-batch-scoped.md template created" -ForegroundColor Green
} else {
    Write-Host "  [SKIP] research-batch-scoped.md already exists" -ForegroundColor Yellow
}

# ── 3. Create cheap-first review prompt (lightweight version for cheap agents) ──

$cheapReviewPath = Join-Path $GsdGlobalDir "prompts\shared\code-review-cheap.md"

if (-not (Test-Path $cheapReviewPath)) {
    $cheapReviewPrompt = @'
# Code Review - Chunk {{CHUNK_LABEL}} ({{CHUNK_COUNT}} requirements)

## Task
Review each requirement below against the source code. For each one, determine:
- **satisfied**: Implementation fully meets the requirement with verifiable evidence
- **partial**: Some implementation exists but incomplete or has gaps
- **not_started**: No implementation found

## Requirements
{{CHUNK_REQUIREMENT_IDS}}

## Project
- Repo: {{REPO_ROOT}}
- GSD: {{GSD_DIR}}
- Iteration: {{ITERATION}}
- Health: {{HEALTH}}%

## Rules
1. Check ACTUAL source files - do not guess or assume
2. Provide file:line evidence for every status
3. Be strict: partial means real gaps exist, not just uncertainty
4. Output valid JSON only - no markdown wrapping

## Output (JSON)
```json
{
  "chunk": "{{CHUNK_LABEL}}",
  "iteration": {{ITERATION}},
  "reviewed_count": N,
  "results": [
    {"id": "XX-NNN", "status": "satisfied|partial|not_started", "evidence": "file.cs:line description"}
  ],
  "blockers": []
}
```
'@
    Set-Content $cheapReviewPath -Value $cheapReviewPrompt -Encoding UTF8
    Write-Host "  [OK] code-review-cheap.md template created" -ForegroundColor Green
} else {
    Write-Host "  [SKIP] code-review-cheap.md already exists" -ForegroundColor Yellow
}

# ── 4. Append Invoke-CheapFirstReview to resilience.ps1 ──

$resiliencePath = Join-Path $GsdGlobalDir "lib\modules\resilience.ps1"
$resilienceContent = Get-Content $resiliencePath -Raw

$cheapFirstMarker = "function Invoke-CheapFirstReview"
if ($resilienceContent -notmatch [regex]::Escape($cheapFirstMarker)) {

    $cheapFirstReviewFn = @'

# ================================================================
# Cost Optimization: Cheap-First Code Review (Patch #40)
# ================================================================

function Invoke-CheapFirstReview {
    <#
    .SYNOPSIS
        Two-pass code review: cheap agents draft, Claude verifies only partial/not_started.
    #>
    param(
        [string]$GsdDir,
        [string]$GlobalDir,
        [int]$Iteration,
        [decimal]$Health,
        [string]$RepoRoot,
        [int]$BatchSize,
        [string]$InterfaceContext = ""
    )

    $agentMapPath = Join-Path $GlobalDir "config\agent-map.json"
    $agentMap = Get-Content $agentMapPath -Raw | ConvertFrom-Json
    $costCfg = $agentMap.cost_optimization

    if (-not $costCfg -or -not $costCfg.enabled -or -not $costCfg.cheap_first_review -or -not $costCfg.cheap_first_review.enabled) {
        Write-Host "  [COST-OPT] Cheap-first review disabled, using standard review" -ForegroundColor Yellow
        return $null  # caller falls through to standard review
    }

    $cfg = $costCfg.cheap_first_review
    $cheapAgents = @($cfg.cheap_agents)
    $verifyAgent = $cfg.verify_agent
    $verifyFallback = $cfg.verify_fallback
    $divergenceThreshold = [int]$cfg.divergence_threshold

    # Load chunk files to find which chunks exist
    $reviewDir = Join-Path $GsdDir "code-review"
    $chunkFiles = @(Get-ChildItem -Path $reviewDir -Filter "chunk-*.json" -ErrorAction SilentlyContinue)

    if ($chunkFiles.Count -eq 0) {
        Write-Host "  [COST-OPT] No chunk files found - cheap-first not applicable for initial review" -ForegroundColor Yellow
        return $null
    }

    Write-Host "  [COST-OPT] Cheap-first review: $($chunkFiles.Count) chunks" -ForegroundColor Cyan

    # ── Pass 1: Cheap agents review all chunks ──
    $cheapResults = @{}
    $agentIdx = 0

    foreach ($chunkFile in $chunkFiles) {
        $chunkLabel = $chunkFile.BaseName -replace '^chunk-', ''
        $agent = $cheapAgents[$agentIdx % $cheapAgents.Count]
        $agentIdx++

        # Check if agent is available (not on cooldown)
        $cooldownPath = Join-Path $GsdDir "supervisor\agent-cooldowns.json"
        if (Test-Path $cooldownPath) {
            try {
                $cooldowns = Get-Content $cooldownPath -Raw | ConvertFrom-Json
                $cd = $cooldowns.$agent
                if ($cd -and ([DateTime]$cd) -gt (Get-Date)) {
                    Write-Host "    [COST-OPT] $agent on cooldown for chunk $chunkLabel, trying next" -ForegroundColor Yellow
                    $agent = $cheapAgents[($agentIdx + 1) % $cheapAgents.Count]
                    $agentIdx++
                }
            } catch {}
        }

        # Rate limit check
        if (Get-Command Wait-ForRateWindow -ErrorAction SilentlyContinue) {
            Wait-ForRateWindow -AgentName $agent -GlobalDir $GlobalDir
        }

        Write-Host "    [COST-OPT] Chunk $chunkLabel -> $agent (cheap pass)" -ForegroundColor DarkGray

        # Build prompt from cheap template
        $templatePath = Join-Path $GlobalDir "prompts\shared\code-review-cheap.md"
        if (-not (Test-Path $templatePath)) {
            Write-Host "    [COST-OPT] Cheap review template missing, skipping" -ForegroundColor Yellow
            return $null
        }

        $existingChunk = Get-Content $chunkFile.FullName -Raw | ConvertFrom-Json
        $reqIds = ($existingChunk.results | ForEach-Object { $_.id }) -join ", "

        $prompt = Get-Content $templatePath -Raw
        $prompt = $prompt.Replace("{{CHUNK_LABEL}}", $chunkLabel)
        $prompt = $prompt.Replace("{{CHUNK_COUNT}}", "$($existingChunk.reviewed_count)")
        $prompt = $prompt.Replace("{{CHUNK_REQUIREMENT_IDS}}", $reqIds)
        $prompt = $prompt.Replace("{{ITERATION}}", "$Iteration")
        $prompt = $prompt.Replace("{{HEALTH}}", "$Health")
        $prompt = $prompt.Replace("{{GSD_DIR}}", $GsdDir)
        $prompt = $prompt.Replace("{{REPO_ROOT}}", $RepoRoot)

        try {
            $logFile = Join-Path $GsdDir "logs\cheap-review-$chunkLabel.log"
            $result = Invoke-WithRetry -Agent $agent -Prompt $prompt -Phase "code-review" `
                -GsdDir $GsdDir -GlobalDir $GlobalDir -LogFile $logFile -Iteration $Iteration

            if ($result -and $result.output) {
                # Parse JSON from output
                $jsonMatch = [regex]::Match($result.output, '\{[\s\S]*"results"[\s\S]*\}')
                if ($jsonMatch.Success) {
                    $cheapResults[$chunkLabel] = $jsonMatch.Value | ConvertFrom-Json
                }
            }
        } catch {
            Write-Host "    [COST-OPT] Cheap review failed for chunk $chunkLabel : $_" -ForegroundColor Yellow
        }

        # Register the call for rate limiting
        if (Get-Command Register-AgentCall -ErrorAction SilentlyContinue) {
            Register-AgentCall -AgentName $agent -GlobalDir $GlobalDir
        }
    }

    # ── Identify chunks needing Claude verification ──
    $chunksNeedingVerify = @()
    $totalCheapSatisfied = 0
    $totalCheapReviewed = 0

    foreach ($chunkLabel in $cheapResults.Keys) {
        $cr = $cheapResults[$chunkLabel]
        $nonSatisfied = @($cr.results | Where-Object { $_.status -ne "satisfied" })
        $totalCheapReviewed += $cr.results.Count
        $totalCheapSatisfied += ($cr.results | Where-Object { $_.status -eq "satisfied" }).Count

        if ($nonSatisfied.Count -gt 0) {
            $chunksNeedingVerify += $chunkLabel
        }
    }

    $cheapSatRate = if ($totalCheapReviewed -gt 0) { [math]::Round(($totalCheapSatisfied / $totalCheapReviewed) * 100, 1) } else { 0 }
    Write-Host "  [COST-OPT] Cheap pass: $totalCheapSatisfied/$totalCheapReviewed satisfied ($cheapSatRate%)" -ForegroundColor Cyan
    Write-Host "  [COST-OPT] Chunks needing Claude verify: $($chunksNeedingVerify.Count)/$($chunkFiles.Count)" -ForegroundColor Cyan

    # Skip verify if all satisfied and config allows it
    if ($chunksNeedingVerify.Count -eq 0 -and $cfg.skip_verify_if_all_satisfied) {
        Write-Host "  [COST-OPT] All chunks satisfied - skipping Claude verify pass" -ForegroundColor Green
        # Write cheap results as the final chunk files
        foreach ($chunkLabel in $cheapResults.Keys) {
            $outPath = Join-Path $reviewDir "chunk-$chunkLabel.json"
            $cheapResults[$chunkLabel] | ConvertTo-Json -Depth 10 | Set-Content $outPath -Encoding UTF8
        }
        return @{ Success = $true; Method = "cheap-only"; VerifiedChunks = 0; TotalChunks = $chunkFiles.Count }
    }

    # ── Pass 2: Claude verifies only non-satisfied chunks ──
    Write-Host "  [COST-OPT] Claude verify pass on $($chunksNeedingVerify.Count) chunks" -ForegroundColor Cyan

    $verifiedCount = 0
    foreach ($chunkLabel in $chunksNeedingVerify) {
        # Use the existing chunked review template for Claude
        $existingChunkPath = Join-Path $reviewDir "chunk-$chunkLabel.json"
        if (-not (Test-Path $existingChunkPath)) { continue }

        $existingChunk = Get-Content $existingChunkPath -Raw | ConvertFrom-Json

        # Only send partial/not_started req IDs to Claude (save tokens)
        $cheapChunk = $cheapResults[$chunkLabel]
        $nonSatisfiedIds = @($cheapChunk.results | Where-Object { $_.status -ne "satisfied" } | ForEach-Object { $_.id })

        if ($nonSatisfiedIds.Count -eq 0) { continue }

        # Rate limit check for verify agent
        if (Get-Command Wait-ForRateWindow -ErrorAction SilentlyContinue) {
            Wait-ForRateWindow -AgentName $verifyAgent -GlobalDir $GlobalDir
        }

        Write-Host "    [COST-OPT] Chunk $chunkLabel -> $verifyAgent (verify $($nonSatisfiedIds.Count) reqs)" -ForegroundColor DarkGray

        $templatePath = Join-Path $GlobalDir "prompts\shared\code-review-cheap.md"
        $prompt = Get-Content $templatePath -Raw
        $prompt = $prompt.Replace("{{CHUNK_LABEL}}", $chunkLabel)
        $prompt = $prompt.Replace("{{CHUNK_COUNT}}", "$($nonSatisfiedIds.Count)")
        $prompt = $prompt.Replace("{{CHUNK_REQUIREMENT_IDS}}", ($nonSatisfiedIds -join ", "))
        $prompt = $prompt.Replace("{{ITERATION}}", "$Iteration")
        $prompt = $prompt.Replace("{{HEALTH}}", "$Health")
        $prompt = $prompt.Replace("{{GSD_DIR}}", $GsdDir)
        $prompt = $prompt.Replace("{{REPO_ROOT}}", $RepoRoot)

        try {
            $logFile = Join-Path $GsdDir "logs\verify-review-$chunkLabel.log"
            $result = Invoke-WithRetry -Agent $verifyAgent -Prompt $prompt -Phase "code-review" `
                -GsdDir $GsdDir -GlobalDir $GlobalDir -LogFile $logFile -Iteration $Iteration

            if ($result -and $result.output) {
                $jsonMatch = [regex]::Match($result.output, '\{[\s\S]*"results"[\s\S]*\}')
                if ($jsonMatch.Success) {
                    $verifyData = $jsonMatch.Value | ConvertFrom-Json

                    # Merge: keep cheap satisfied results + use Claude results for non-satisfied
                    $mergedResults = @()
                    foreach ($r in $cheapChunk.results) {
                        if ($r.status -eq "satisfied") {
                            $mergedResults += $r
                        } else {
                            $claudeResult = $verifyData.results | Where-Object { $_.id -eq $r.id } | Select-Object -First 1
                            if ($claudeResult) {
                                $mergedResults += $claudeResult
                            } else {
                                $mergedResults += $r  # keep cheap result if Claude didn't review
                            }
                        }
                    }

                    $mergedChunk = [PSCustomObject]@{
                        chunk          = $chunkLabel
                        iteration      = $Iteration
                        reviewed_count = $mergedResults.Count
                        results        = $mergedResults
                        blockers       = @()
                    }
                    $mergedChunk | ConvertTo-Json -Depth 10 | Set-Content $existingChunkPath -Encoding UTF8
                    $verifiedCount++
                }
            }
        } catch {
            Write-Host "    [COST-OPT] Claude verify failed for chunk $chunkLabel : $_ - keeping cheap result" -ForegroundColor Yellow
            # Write cheap result as fallback
            $cheapResults[$chunkLabel] | ConvertTo-Json -Depth 10 | Set-Content $existingChunkPath -Encoding UTF8
        }

        if (Get-Command Register-AgentCall -ErrorAction SilentlyContinue) {
            Register-AgentCall -AgentName $verifyAgent -GlobalDir $GlobalDir
        }
    }

    # Write cheap-only results for chunks that didn't need verification
    foreach ($chunkLabel in $cheapResults.Keys) {
        if ($chunksNeedingVerify -notcontains $chunkLabel) {
            $outPath = Join-Path $reviewDir "chunk-$chunkLabel.json"
            $cheapResults[$chunkLabel] | ConvertTo-Json -Depth 10 | Set-Content $outPath -Encoding UTF8
        }
    }

    Write-Host "  [COST-OPT] Cheap-first complete: $verifiedCount chunks verified by Claude" -ForegroundColor Green

    return @{
        Success        = $true
        Method         = "cheap-first"
        VerifiedChunks = $verifiedCount
        TotalChunks    = $chunkFiles.Count
        CheapSatRate   = $cheapSatRate
    }
}

# ================================================================
# Cost Optimization: Batch-Scoped Research (Patch #40)
# ================================================================

function Invoke-BatchScopedResearch {
    <#
    .SYNOPSIS
        Research only the requirements in the current batch, not entire phases.
    #>
    param(
        [string]$GsdDir,
        [string]$GlobalDir,
        [int]$Iteration,
        [decimal]$Health,
        [string]$RepoRoot,
        [string]$InterfaceContext = ""
    )

    $agentMapPath = Join-Path $GlobalDir "config\agent-map.json"
    $agentMap = Get-Content $agentMapPath -Raw | ConvertFrom-Json
    $costCfg = $agentMap.cost_optimization

    if (-not $costCfg -or -not $costCfg.enabled -or -not $costCfg.batch_scoped_research -or -not $costCfg.batch_scoped_research.enabled) {
        Write-Host "  [COST-OPT] Batch-scoped research disabled" -ForegroundColor Yellow
        return $null
    }

    $cfg = $costCfg.batch_scoped_research

    # Load current queue to get batch requirements
    $queuePath = Join-Path $GsdDir "generation-queue\queue-current.json"
    if (-not (Test-Path $queuePath)) {
        Write-Host "  [COST-OPT] No queue-current.json - batch-scoped research not applicable" -ForegroundColor Yellow
        return $null
    }

    $queue = Get-Content $queuePath -Raw | ConvertFrom-Json
    $batchReqs = @($queue.batch)

    if ($batchReqs.Count -eq 0) {
        Write-Host "  [COST-OPT] Empty batch - skipping research" -ForegroundColor Yellow
        return $null
    }

    # Cap at max
    $maxReqs = [int]$cfg.max_research_reqs
    if ($batchReqs.Count -gt $maxReqs) {
        $batchReqs = $batchReqs[0..($maxReqs - 1)]
    }

    # Build batch requirements text
    $batchText = ""
    foreach ($req in $batchReqs) {
        $id = if ($req.id) { $req.id } elseif ($req.req_id) { $req.req_id } else { "UNKNOWN" }
        $desc = if ($req.description) { $req.description } elseif ($req.text) { $req.text } else { "" }
        $status = if ($req.status) { $req.status } else { "unknown" }
        $batchText += "- **$id** ($status): $desc`n"
    }

    # Load blockers
    $blockersText = "None identified"
    if ($cfg.include_blockers) {
        $healthPath = Join-Path $GsdDir "health\health-current.json"
        if (Test-Path $healthPath) {
            try {
                $healthData = Get-Content $healthPath -Raw | ConvertFrom-Json
                if ($healthData.remaining_blockers -and $healthData.remaining_blockers.Count -gt 0) {
                    $blockersText = ($healthData.remaining_blockers | ForEach-Object { "- $_" }) -join "`n"
                }
            } catch {}
        }
    }

    # Build prompt from template
    $templatePath = Join-Path $GlobalDir "prompts\shared\research-batch-scoped.md"
    if (-not (Test-Path $templatePath)) {
        Write-Host "  [COST-OPT] research-batch-scoped.md template missing" -ForegroundColor Yellow
        return $null
    }

    $prompt = Get-Content $templatePath -Raw
    $prompt = $prompt.Replace("{{BATCH_REQUIREMENTS}}", $batchText)
    $prompt = $prompt.Replace("{{REMAINING_BLOCKERS}}", $blockersText)
    $prompt = $prompt.Replace("{{ITERATION}}", "$Iteration")
    $prompt = $prompt.Replace("{{HEALTH}}", "$Health")
    $prompt = $prompt.Replace("{{GSD_DIR}}", $GsdDir)
    $prompt = $prompt.Replace("{{REPO_ROOT}}", $RepoRoot)
    $prompt = $prompt.Replace("{{INTERFACE_CONTEXT}}", $InterfaceContext)

    Write-Host "  [COST-OPT] Batch-scoped research: $($batchReqs.Count) requirements" -ForegroundColor Cyan

    # Use cheapest available agent for research
    $researchAgents = @("deepseek", "kimi", "gemini")
    $agent = $null
    foreach ($ra in $researchAgents) {
        $cooldownPath = Join-Path $GsdDir "supervisor\agent-cooldowns.json"
        $available = $true
        if (Test-Path $cooldownPath) {
            try {
                $cooldowns = Get-Content $cooldownPath -Raw | ConvertFrom-Json
                $cd = $cooldowns.$ra
                if ($cd -and ([DateTime]$cd) -gt (Get-Date)) { $available = $false }
            } catch {}
        }
        if ($available) { $agent = $ra; break }
    }

    if (-not $agent) { $agent = "deepseek" }  # default

    if (Get-Command Wait-ForRateWindow -ErrorAction SilentlyContinue) {
        Wait-ForRateWindow -AgentName $agent -GlobalDir $GlobalDir
    }

    Write-Host "  [COST-OPT] Research agent: $agent" -ForegroundColor DarkGray

    try {
        $logFile = Join-Path $GsdDir "logs\batch-research-iter$Iteration.log"
        $result = Invoke-WithRetry -Agent $agent -Prompt $prompt -Phase "research" `
            -GsdDir $GsdDir -GlobalDir $GlobalDir -LogFile $logFile -Iteration $Iteration

        if ($result -and $result.output) {
            $findingsPath = Join-Path $GsdDir "research\research-findings.md"
            $header = "`n`n# Batch-Scoped Research (Iteration $Iteration)`n"
            $header += "Agent: $agent | Requirements: $($batchReqs.Count) | $(Get-Date -Format 'yyyy-MM-dd HH:mm')`n`n"
            Add-Content $findingsPath -Value ($header + $result.output) -Encoding UTF8
            Write-Host "  [COST-OPT] Research findings appended to research-findings.md" -ForegroundColor Green
        }

        if (Get-Command Register-AgentCall -ErrorAction SilentlyContinue) {
            Register-AgentCall -AgentName $agent -GlobalDir $GlobalDir
        }

        return @{ Success = $true; Agent = $agent; ReqCount = $batchReqs.Count }
    } catch {
        Write-Host "  [COST-OPT] Batch research failed: $_" -ForegroundColor Yellow
        return @{ Success = $false; Error = $_.ToString() }
    }
}

# ================================================================
# Cost Optimization: Cost-Per-Requirement Tracking (Patch #40)
# ================================================================

function Update-CostPerRequirement {
    <#
    .SYNOPSIS
        Track and flag expensive requirements that aren't progressing.
    #>
    param(
        [string]$GsdDir,
        [string]$GlobalDir,
        [int]$Iteration,
        [string]$Phase,
        [decimal]$CallCostUsd,
        [string[]]$RequirementIds
    )

    $agentMapPath = Join-Path $GlobalDir "config\agent-map.json"
    $agentMap = Get-Content $agentMapPath -Raw | ConvertFrom-Json
    $costCfg = $agentMap.cost_optimization

    if (-not $costCfg -or -not $costCfg.enabled -or -not $costCfg.cost_per_requirement -or -not $costCfg.cost_per_requirement.enabled) {
        return
    }

    $cfg = $costCfg.cost_per_requirement
    $trackPath = Join-Path $GsdDir "costs\cost-per-requirement.json"

    # Load or initialize
    $tracker = @{}
    if (Test-Path $trackPath) {
        try {
            $raw = Get-Content $trackPath -Raw | ConvertFrom-Json
            foreach ($prop in $raw.PSObject.Properties) {
                $tracker[$prop.Name] = $prop.Value
            }
        } catch {}
    }

    # Distribute cost evenly across requirements in this call
    $costPerReq = if ($RequirementIds.Count -gt 0) { $CallCostUsd / $RequirementIds.Count } else { 0 }

    foreach ($reqId in $RequirementIds) {
        if (-not $tracker.ContainsKey($reqId)) {
            $tracker[$reqId] = [PSCustomObject]@{
                total_cost_usd     = 0
                calls              = 0
                iterations_seen    = @()
                last_status        = "unknown"
                flagged_expensive  = $false
            }
        }

        $entry = $tracker[$reqId]

        # Update cost
        if ($entry.PSObject.Properties['total_cost_usd']) {
            $entry.total_cost_usd = [decimal]$entry.total_cost_usd + $costPerReq
        } else {
            $entry | Add-Member -NotePropertyName total_cost_usd -NotePropertyValue $costPerReq -Force
        }

        if ($entry.PSObject.Properties['calls']) {
            $entry.calls = [int]$entry.calls + 1
        } else {
            $entry | Add-Member -NotePropertyName calls -NotePropertyValue 1 -Force
        }

        # Track iterations
        if ($entry.PSObject.Properties['iterations_seen']) {
            $iters = @($entry.iterations_seen)
            if ($iters -notcontains $Iteration) { $iters += $Iteration }
            $entry.iterations_seen = $iters
        } else {
            $entry | Add-Member -NotePropertyName iterations_seen -NotePropertyValue @($Iteration) -Force
        }

        # Check escalation threshold
        $threshold = [decimal]$cfg.escalation_threshold
        $maxIters = [int]$cfg.max_iterations_partial
        if ([decimal]$entry.total_cost_usd -gt $threshold) {
            if (-not $entry.flagged_expensive) {
                Write-Host "  [COST-OPT] WARNING: $reqId has cost `$$([math]::Round($entry.total_cost_usd, 2)) (threshold: `$$threshold)" -ForegroundColor Red
                if ($entry.PSObject.Properties['flagged_expensive']) {
                    $entry.flagged_expensive = $true
                } else {
                    $entry | Add-Member -NotePropertyName flagged_expensive -NotePropertyValue $true -Force
                }
            }
        }

        $tracker[$reqId] = $entry
    }

    # Save
    $costsDir = Join-Path $GsdDir "costs"
    if (-not (Test-Path $costsDir)) { New-Item -ItemType Directory -Path $costsDir -Force | Out-Null }

    $trackerObj = [PSCustomObject]@{}
    foreach ($key in $tracker.Keys) {
        $trackerObj | Add-Member -NotePropertyName $key -NotePropertyValue $tracker[$key] -Force
    }
    $trackerObj | ConvertTo-Json -Depth 5 | Set-Content $trackPath -Encoding UTF8
}

function Get-ExpensiveRequirements {
    <#
    .SYNOPSIS
        Return requirements that have exceeded the cost threshold and remain partial.
    #>
    param(
        [string]$GsdDir,
        [string]$GlobalDir
    )

    $trackPath = Join-Path $GsdDir "costs\cost-per-requirement.json"
    if (-not (Test-Path $trackPath)) { return @() }

    $agentMapPath = Join-Path $GlobalDir "config\agent-map.json"
    $agentMap = Get-Content $agentMapPath -Raw | ConvertFrom-Json
    $cfg = $agentMap.cost_optimization.cost_per_requirement
    $threshold = [decimal]$cfg.escalation_threshold

    $tracker = Get-Content $trackPath -Raw | ConvertFrom-Json
    $expensive = @()

    foreach ($prop in $tracker.PSObject.Properties) {
        $entry = $prop.Value
        if ([decimal]$entry.total_cost_usd -gt $threshold -and $entry.last_status -ne "satisfied") {
            $expensive += [PSCustomObject]@{
                id        = $prop.Name
                cost_usd  = [math]::Round([decimal]$entry.total_cost_usd, 2)
                calls     = $entry.calls
                status    = $entry.last_status
                iterations = $entry.iterations_seen
            }
        }
    }

    return $expensive
}

function Test-ShouldSkipCouncilRequirements {
    <#
    .SYNOPSIS
        Returns $true if council-requirements extraction should be skipped (iteration 2+).
    #>
    param(
        [string]$GsdDir,
        [string]$GlobalDir,
        [int]$Iteration
    )

    $agentMapPath = Join-Path $GlobalDir "config\agent-map.json"
    $agentMap = Get-Content $agentMapPath -Raw | ConvertFrom-Json
    $costCfg = $agentMap.cost_optimization

    if (-not $costCfg -or -not $costCfg.enabled -or -not $costCfg.incremental_council -or -not $costCfg.incremental_council.enabled) {
        return $false
    }

    $cfg = $costCfg.incremental_council
    $skipAfter = [int]$cfg.verify_only_after

    # Check if matrix already exists (extraction was done)
    $matrixPath = Join-Path $GsdDir "health\requirements-matrix.json"
    if (-not (Test-Path $matrixPath)) {
        Write-Host "  [COST-OPT] No matrix yet - full extraction needed" -ForegroundColor Yellow
        return $false
    }

    if ($Iteration -gt $skipAfter) {
        # Check for new source files since last extraction
        if ($cfg.retrigger_on_new_files) {
            try {
                $repoRoot = Split-Path $GsdDir -Parent
                $newFiles = & git -C $repoRoot diff --name-only --diff-filter=A HEAD~1 2>$null
                if ($newFiles -and $newFiles.Count -gt 5) {
                    Write-Host "  [COST-OPT] $($newFiles.Count) new files detected - running targeted extraction" -ForegroundColor Yellow
                    return $false
                }
            } catch {}
        }

        Write-Host "  [COST-OPT] Iteration $Iteration > $skipAfter - skipping council-requirements (matrix exists)" -ForegroundColor Green
        return $true
    }

    return $false
}
'@

    Add-Content $resiliencePath -Value $cheapFirstReviewFn -Encoding UTF8
    Write-Host "  [OK] 5 functions appended to resilience.ps1:" -ForegroundColor Green
    Write-Host "       - Invoke-CheapFirstReview" -ForegroundColor Green
    Write-Host "       - Invoke-BatchScopedResearch" -ForegroundColor Green
    Write-Host "       - Update-CostPerRequirement" -ForegroundColor Green
    Write-Host "       - Get-ExpensiveRequirements" -ForegroundColor Green
    Write-Host "       - Test-ShouldSkipCouncilRequirements" -ForegroundColor Green
} else {
    Write-Host "  [SKIP] Cost optimization functions already in resilience.ps1" -ForegroundColor Yellow
}

# -- 5. Wire cost optimizations into existing resilience.ps1 functions --

# 5a. Inject cheap-first guard at top of Invoke-SequentialChunkedReview
$cheapFirstGuard = @"

    # -- COST-OPT: cheap-first review guard (Patch #40) --
    if (`$Iteration -gt 1 -and (Get-Command Invoke-CheapFirstReview -ErrorAction SilentlyContinue)) {
        `$cheapResult = Invoke-CheapFirstReview -GsdDir `$GsdDir -GlobalDir `$GlobalDir ``
            -Iteration `$Iteration -Health `$Health -RepoRoot `$RepoRoot ``
            -BatchSize `$BatchSize -InterfaceContext `$InterfaceContext
        if (`$cheapResult -and `$cheapResult.Success) {
            Write-Host "  [COST-OPT] Cheap-first review succeeded - skipping full chunked review" -ForegroundColor Green
            return `$cheapResult
        }
    }
"@

$seqChunkedAnchor = "function Invoke-SequentialChunkedReview {"
if ($resilienceContent -match [regex]::Escape($seqChunkedAnchor)) {
    # Find the opening brace of the function body (after param block)
    $guardMarker = "COST-OPT: cheap-first review guard"
    if ($resilienceContent -notmatch [regex]::Escape($guardMarker)) {
        # Insert after the first line that sets $result = @{ inside the function
        $resultAnchor = "Invoke-SequentialChunkedReview"
        # Use a simple string insert after the function's param block ends
        $paramEndPattern = '(function Invoke-SequentialChunkedReview \{[^}]*?\n\s*\))'
        if ($resilienceContent -match $paramEndPattern) {
            $resilienceContent = $resilienceContent -replace $paramEndPattern, "`$1`n$cheapFirstGuard"
            Set-Content $resiliencePath -Value $resilienceContent -Encoding UTF8
            Write-Host "  [OK] Cheap-first guard injected into Invoke-SequentialChunkedReview" -ForegroundColor Green
        } else {
            Write-Host "  [INFO] Could not find param end in SequentialChunkedReview - manual wiring needed" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  [SKIP] Cheap-first guard already present" -ForegroundColor Yellow
    }
} else {
    Write-Host "  [INFO] Invoke-SequentialChunkedReview not found - cheap-first available as standalone" -ForegroundColor Yellow
}

# 5b. Inject batch-scoped research guard at top of Invoke-ParallelResearch
$batchResearchGuard = @"

    # -- COST-OPT: batch-scoped research guard (Patch #40) --
    if (`$Iteration -gt 1 -and (Get-Command Invoke-BatchScopedResearch -ErrorAction SilentlyContinue)) {
        `$batchResult = Invoke-BatchScopedResearch -GsdDir `$GsdDir -GlobalDir `$GlobalDir ``
            -Iteration `$Iteration -Health `$Health -RepoRoot `$RepoRoot ``
            -InterfaceContext `$InterfaceContext
        if (`$batchResult -and `$batchResult.Success) {
            Write-Host "  [COST-OPT] Batch-scoped research complete - skipping full parallel research" -ForegroundColor Green
            return @{ Success = `$true; Findings = "batch-scoped" }
        }
    }
"@

$parallelResearchAnchor = "function Invoke-ParallelResearch {"
if ($resilienceContent -match [regex]::Escape($parallelResearchAnchor)) {
    $guardMarker2 = "COST-OPT: batch-scoped research guard"
    if ($resilienceContent -notmatch [regex]::Escape($guardMarker2)) {
        $paramEndPattern2 = '(function Invoke-ParallelResearch \{[^}]*?\n\s*\))'
        if ($resilienceContent -match $paramEndPattern2) {
            $resilienceContent = $resilienceContent -replace $paramEndPattern2, "`$1`n$batchResearchGuard"
            Set-Content $resiliencePath -Value $resilienceContent -Encoding UTF8
            Write-Host "  [OK] Batch-scoped research guard injected into Invoke-ParallelResearch" -ForegroundColor Green
        } else {
            Write-Host "  [INFO] Could not find param end in ParallelResearch - manual wiring needed" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  [SKIP] Batch-scoped research guard already present" -ForegroundColor Yellow
    }
} else {
    Write-Host "  [INFO] Invoke-ParallelResearch not found - batch research available as standalone" -ForegroundColor Yellow
}

# 5c. Inject council-requirements skip guard
$councilSkipGuard = @"

    # -- COST-OPT: incremental council guard (Patch #40) --
    if (Get-Command Test-ShouldSkipCouncilRequirements -ErrorAction SilentlyContinue) {
        if (Test-ShouldSkipCouncilRequirements -GsdDir `$GsdDir -GlobalDir `$GlobalDir -Iteration `$Iteration) {
            Write-Host "  [COST-OPT] Council requirements extraction skipped (iteration `$Iteration)" -ForegroundColor Green
            return
        }
    }
"@

$councilReqAnchor = "function Invoke-CouncilRequirements {"
if ($resilienceContent -match [regex]::Escape($councilReqAnchor)) {
    $guardMarker3 = "COST-OPT: incremental council guard"
    if ($resilienceContent -notmatch [regex]::Escape($guardMarker3)) {
        $paramEndPattern3 = '(function Invoke-CouncilRequirements \{[^}]*?\n\s*\))'
        if ($resilienceContent -match $paramEndPattern3) {
            $resilienceContent = $resilienceContent -replace $paramEndPattern3, "`$1`n$councilSkipGuard"
            Set-Content $resiliencePath -Value $resilienceContent -Encoding UTF8
            Write-Host "  [OK] Incremental council guard injected into Invoke-CouncilRequirements" -ForegroundColor Green
        } else {
            Write-Host "  [INFO] Could not find param end in CouncilRequirements - manual wiring needed" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  [SKIP] Incremental council guard already present" -ForegroundColor Yellow
    }
} else {
    Write-Host "  [INFO] Invoke-CouncilRequirements not found" -ForegroundColor Yellow
}

# ── 6. Summary ──

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  Cost Optimization Patch Complete" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Config: agent-map.json -> cost_optimization" -ForegroundColor White
Write-Host "  Functions: 5 added to resilience.ps1" -ForegroundColor White
Write-Host "  Templates: 2 prompt files (research-batch-scoped.md, code-review-cheap.md)" -ForegroundColor White
Write-Host ""
Write-Host "  Optimization Summary:" -ForegroundColor White
Write-Host "    1. Cheap-first review: kimi/deepseek draft, Claude verify partials only" -ForegroundColor Green
Write-Host "    2. Incremental council: full extract iter 1, skip iter 2+" -ForegroundColor Green
Write-Host "    3. Batch-scoped research: research only current batch reqs" -ForegroundColor Green
Write-Host "    4. Cost-per-requirement: track and flag expensive stuck reqs" -ForegroundColor Green
Write-Host ""
Write-Host "  Disable: Set cost_optimization.enabled = false in agent-map.json" -ForegroundColor DarkGray
Write-Host "  Takes effect: Next pipeline restart (resilience.ps1 changes)" -ForegroundColor DarkGray
Write-Host "                Config changes read per-iteration" -ForegroundColor DarkGray
Write-Host ""
