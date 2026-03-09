# ============================================================
# Rate-Limit-Aware Chunked Code Review (v2)
# Dynamically calculates chunk count and size based on each
# agent's RPM from model-registry.json. Uses all 7 agents
# across multiple waves to stay well under rate limits.
# Appended to resilience.ps1 by patch script.
# ============================================================

function Invoke-SequentialChunkedReview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GsdDir,
        [Parameter(Mandatory)][string]$GlobalDir,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][int]$Iteration,
        [Parameter(Mandatory)][double]$Health,
        [int]$CurrentBatchSize = 2,
        [string]$InterfaceContext = "",
        [switch]$DryRun
    )

    # ── 1. Load config from agent-map.json ──
    $agentMapPath = Join-Path $GlobalDir "config\agent-map.json"
    $registryPath = Join-Path $GlobalDir "config\model-registry.json"
    $config = @{
        safety_factor = 0.5
        min_chunk_size = 5
        max_chunk_size = 30
        inter_wave_cooldown_seconds = 20
        inter_chunk_cooldown_seconds = 10
        min_success_ratio = 0.6
        fallback_to_single_agent = $true
        fallback_agent = "codex"
        agent_pool = @("claude", "codex", "gemini", "kimi", "deepseek", "glm5", "minimax")
    }

    if (Test-Path $agentMapPath) {
        try {
            $agentMap = Get-Content $agentMapPath -Raw | ConvertFrom-Json
            if ($agentMap.review_chunked) {
                $rc = $agentMap.review_chunked
                if ($null -ne $rc.safety_factor) { $config.safety_factor = $rc.safety_factor }
                if ($null -ne $rc.min_chunk_size) { $config.min_chunk_size = $rc.min_chunk_size }
                if ($null -ne $rc.max_chunk_size) { $config.max_chunk_size = $rc.max_chunk_size }
                if ($null -ne $rc.inter_wave_cooldown_seconds) { $config.inter_wave_cooldown_seconds = $rc.inter_wave_cooldown_seconds }
                if ($null -ne $rc.inter_chunk_cooldown_seconds) { $config.inter_chunk_cooldown_seconds = $rc.inter_chunk_cooldown_seconds }
                if ($null -ne $rc.min_success_ratio) { $config.min_success_ratio = $rc.min_success_ratio }
                if ($null -ne $rc.fallback_to_single_agent) { $config.fallback_to_single_agent = $rc.fallback_to_single_agent }
                if ($rc.fallback_agent) { $config.fallback_agent = $rc.fallback_agent }
                if ($rc.agent_pool) { $config.agent_pool = @($rc.agent_pool) }
            }
        } catch { Write-Host "  [CHUNK-REVIEW] Could not read agent-map.json config, using defaults" -ForegroundColor Yellow }
    }

    # ── 2. Load model registry for rate limits ──
    $agentRpm = @{}  # agent -> safe requests per wave
    $agentCooldownMin = @{}  # agent -> cooldown minutes
    $registry = $null

    if (Test-Path $registryPath) {
        try {
            $registry = Get-Content $registryPath -Raw | ConvertFrom-Json
        } catch { $registry = $null }
    }

    # Build per-agent capacity map from rate_limits
    $availableAgents = @()
    $cooldownPath = Join-Path $GsdDir "supervisor\agent-cooldowns.json"
    $cooldowns = @{}
    if (Test-Path $cooldownPath) {
        try { $cooldowns = Get-Content $cooldownPath -Raw | ConvertFrom-Json } catch { $cooldowns = @{} }
    }

    foreach ($agentName in $config.agent_pool) {
        # Skip agents on cooldown
        $cdExpiry = $null
        if ($cooldowns.PSObject -and $cooldowns.PSObject.Properties[$agentName]) {
            $cdExpiry = $cooldowns.$agentName
        } elseif ($cooldowns -is [hashtable] -and $cooldowns.ContainsKey($agentName)) {
            $cdExpiry = $cooldowns[$agentName]
        }
        if ($cdExpiry) {
            try {
                $expiryTime = [datetime]::Parse($cdExpiry)
                if ($expiryTime -gt (Get-Date)) {
                    Write-Host "  [CHUNK-REVIEW] $agentName on cooldown until $cdExpiry --skipping" -ForegroundColor DarkGray
                    continue
                }
            } catch { }
        }

        # Check if agent has review role
        $agentDef = $null
        if ($registry -and $registry.agents.PSObject.Properties[$agentName]) {
            $agentDef = $registry.agents.$agentName
        }
        if ($agentDef -and $agentDef.role -and ("review" -notin @($agentDef.role))) {
            continue
        }

        # Check enabled flag (REST agents)
        if ($agentDef -and $null -ne $agentDef.enabled -and -not $agentDef.enabled) {
            continue
        }

        # Get RPM from rate_limits (default 10 if not specified)
        $rpm = 10
        $cdMin = 30
        if ($agentDef -and $agentDef.rate_limits) {
            if ($agentDef.rate_limits.rpm) { $rpm = [int]$agentDef.rate_limits.rpm }
            if ($agentDef.rate_limits.cooldown_minutes) { $cdMin = [int]$agentDef.rate_limits.cooldown_minutes }
        }

        # Safe capacity = floor(RPM * safety_factor) --this is the max reqs we send to this agent per wave
        $safeCapacity = [math]::Floor($rpm * $config.safety_factor)
        if ($safeCapacity -lt 1) { $safeCapacity = 1 }

        $agentRpm[$agentName] = $safeCapacity
        $agentCooldownMin[$agentName] = $cdMin
        $availableAgents += $agentName
    }

    if ($availableAgents.Count -eq 0) {
        Write-Host "  [CHUNK-REVIEW] No available agents (all on cooldown or disabled)" -ForegroundColor Red
        return @{ Success = $false; NewHealth = $Health; ChunksCompleted = 0; ChunksTotal = 0 }
    }

    # ── 3. Load requirements matrix ──
    $matrixFile = Join-Path $GsdDir "health\requirements-matrix.json"
    if (-not (Test-Path $matrixFile)) {
        Write-Host "  [CHUNK-REVIEW] No requirements-matrix.json found" -ForegroundColor Red
        return @{ Success = $false; NewHealth = $Health; ChunksCompleted = 0; ChunksTotal = 0 }
    }
    $matrix = Get-Content $matrixFile -Raw | ConvertFrom-Json
    $allReqs = @($matrix.requirements)
    if ($allReqs.Count -eq 0) {
        Write-Host "  [CHUNK-REVIEW] Empty requirements matrix" -ForegroundColor Red
        return @{ Success = $false; NewHealth = $Health; ChunksCompleted = 0; ChunksTotal = 0 }
    }

    # ── 4. Calculate dynamic chunk sizes per agent ──
    # Each agent gets at most min(safeCapacity, max_chunk_size) reqs, at least min_chunk_size
    # Total capacity across all agents determines how many waves we need

    $totalCapacity = 0
    $agentChunkSize = @{}
    foreach ($agent in $availableAgents) {
        $chunkSz = $agentRpm[$agent]
        if ($chunkSz -gt $config.max_chunk_size) { $chunkSz = $config.max_chunk_size }
        if ($chunkSz -lt $config.min_chunk_size) { $chunkSz = $config.min_chunk_size }
        $agentChunkSize[$agent] = $chunkSz
        $totalCapacity += $chunkSz
    }

    $totalReqs = $allReqs.Count
    $numWaves = [math]::Ceiling($totalReqs / $totalCapacity)
    if ($numWaves -lt 1) { $numWaves = 1 }

    # Build chunk assignments: distribute reqs across agents and waves
    $chunks = @()
    $reqIndex = 0
    $chunkLabelCounter = 0
    $chunkLabels = @("A","B","C","D","E","F","G","H","I","J","K","L","M","N","O","P","Q","R","S","T","U","V","W","X","Y","Z")

    for ($wave = 1; $wave -le $numWaves; $wave++) {
        foreach ($agent in $availableAgents) {
            if ($reqIndex -ge $totalReqs) { break }
            $sz = $agentChunkSize[$agent]
            $remaining = $totalReqs - $reqIndex
            if ($sz -gt $remaining) { $sz = $remaining }
            if ($sz -le 0) { continue }

            $label = if ($chunkLabelCounter -lt $chunkLabels.Count) { $chunkLabels[$chunkLabelCounter] } else { "Z$chunkLabelCounter" }
            $chunks += @{
                Label = $label
                Agent = $agent
                Wave  = $wave
                Reqs  = @($allReqs[$reqIndex..($reqIndex + $sz - 1)])
            }
            $reqIndex += $sz
            $chunkLabelCounter++
        }
    }

    $totalChunks = $chunks.Count
    Write-Host "  [CHUNK-REVIEW] $totalReqs requirements -> $totalChunks chunks across $numWaves wave(s) using $($availableAgents.Count) agents" -ForegroundColor Cyan
    Write-Host "  [CHUNK-REVIEW] Agent capacity (safe RPM/2): $( ($availableAgents | ForEach-Object { "$_=$($agentChunkSize[$_])" }) -join ', ' )" -ForegroundColor DarkCyan

    $result = @{ Success = $false; NewHealth = $Health; ChunksCompleted = 0; ChunksTotal = $totalChunks }

    # Ensure output directory exists
    $reviewDir = Join-Path $GsdDir "code-review"
    if (-not (Test-Path $reviewDir)) { New-Item -Path $reviewDir -ItemType Directory -Force | Out-Null }

    # ── 5. Load prompt template ──
    $templatePath = Join-Path $GlobalDir "prompts\claude\code-review-chunked.md"
    if (-not (Test-Path $templatePath)) {
        Write-Host "  [CHUNK-REVIEW] Missing template: $templatePath" -ForegroundColor Red
        return $result
    }
    $templateRaw = Get-Content $templatePath -Raw

    # ── 6. Execute chunks wave by wave ──
    $completedChunks = @()
    $currentWave = 0

    foreach ($chunk in $chunks) {
        $label = $chunk.Label
        $agent = $chunk.Agent
        $wave  = $chunk.Wave
        $reqIds = ($chunk.Reqs | ForEach-Object { $_.id }) -join ", "
        $reqCount = $chunk.Reqs.Count

        if ($reqCount -eq 0) { continue }

        # Wave transition cooldown
        if ($wave -gt $currentWave) {
            if ($currentWave -gt 0) {
                $waveCooldown = $config.inter_wave_cooldown_seconds
                Write-Host "  [WAVE] Wave $currentWave complete. ${waveCooldown}s cooldown before wave $wave..." -ForegroundColor DarkGray
                Start-Sleep -Seconds $config.inter_wave_cooldown_seconds
            }
            $currentWave = $wave
            Write-Host "  [WAVE $wave/$numWaves] Starting wave with $($availableAgents.Count) agents" -ForegroundColor Cyan
        }

        Write-Host "  [CHUNK-$label] $agent reviewing $reqCount reqs (wave $wave): $($reqIds.Substring(0, [math]::Min(80, $reqIds.Length)))..." -ForegroundColor Cyan

        # Build prompt from template
        $prompt = $templateRaw
        $prompt = $prompt.Replace("{{ITERATION}}", "$Iteration")
        $prompt = $prompt.Replace("{{HEALTH}}", "$Health")
        $prompt = $prompt.Replace("{{GSD_DIR}}", $GsdDir)
        $prompt = $prompt.Replace("{{REPO_ROOT}}", $RepoRoot)
        $prompt = $prompt.Replace("{{CHUNK_LABEL}}", $label)
        $prompt = $prompt.Replace("{{TOTAL_CHUNKS}}", "$totalChunks")
        $prompt = $prompt.Replace("{{CHUNK_COUNT}}", "$reqCount")
        $prompt = $prompt.Replace("{{CHUNK_REQUIREMENT_IDS}}", $reqIds)
        $prompt = $prompt.Replace("{{BATCH_SIZE}}", "$CurrentBatchSize")
        $prompt = $prompt.Replace("{{INTERFACE_CONTEXT}}", $InterfaceContext)

        # Append file map context
        $fileTreePath = Join-Path $GsdDir "file-map-tree.md"
        if (Test-Path $fileTreePath) {
            $prompt += "`n`n## Repository File Map`nRead the tree file at: $fileTreePath`n"
        }

        # Append supervisor hints
        $errorCtxPath = Join-Path $GsdDir "supervisor\error-context.md"
        $hintPath = Join-Path $GsdDir "supervisor\prompt-hints.md"
        if (Test-Path $errorCtxPath) { $prompt += "`n`n## Previous Iteration Errors`n" + (Get-Content $errorCtxPath -Raw) }
        if (Test-Path $hintPath) { $prompt += "`n`n## Supervisor Instructions`n" + (Get-Content $hintPath -Raw) }

        if ($DryRun) {
            Write-Host "  [CHUNK-$label] DRY RUN: would invoke $agent" -ForegroundColor DarkGray
            $completedChunks += $label  # Count dry run as success for testing
            continue
        }

        # Invoke agent with MaxAttempts 1 --rotation is handled by trying the next chunk's agent
        $logFile = Join-Path $GsdDir "logs\iter${Iteration}-1-chunk-${label}.log"

        $invokeParams = @{
            Agent            = $agent
            Prompt           = $prompt
            Phase            = "code-review"
            LogFile          = $logFile
            CurrentBatchSize = $CurrentBatchSize
            GsdDir           = $GsdDir
            MaxAttempts      = 1
        }
        if ($agent -eq "claude") {
            $invokeParams["AllowedTools"] = "Read,Write,Bash"
        }

        if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
            Update-EngineStatus -GsdDir $GsdDir -State "running" -Phase "code-review" -Agent $agent `
                -Iteration $Iteration -HealthScore $Health -BatchSize $CurrentBatchSize `
                -Attempt "chunk-$label/$totalChunks (wave $wave/$numWaves)" -ErrorsThisIteration 0
        }

        $invokeResult = Invoke-WithRetry @invokeParams

        # Check if chunk file was written
        $chunkFile = Join-Path $GsdDir "code-review\chunk-${label}.json"
        if (Test-Path $chunkFile) {
            $completedChunks += $label
            Write-Host "  [CHUNK-$label] Completed by $agent" -ForegroundColor Green
        } elseif ($invokeResult -and $invokeResult.ExitCode -eq 0) {
            $completedChunks += $label
            Write-Host "  [CHUNK-$label] Agent completed (no chunk file, may have written health directly)" -ForegroundColor Yellow
        } else {
            Write-Host "  [CHUNK-$label] $agent failed --will retry in fallback pass" -ForegroundColor Yellow
        }

        # Inter-chunk cooldown within the same wave
        if ($config.inter_chunk_cooldown_seconds -gt 0) {
            Start-Sleep -Seconds $config.inter_chunk_cooldown_seconds
        }
    }

    $result.ChunksCompleted = $completedChunks.Count
    $chunkStatusColor = if ($completedChunks.Count -ge [math]::Ceiling($totalChunks * $config.min_success_ratio)) { "Green" } else { "Yellow" }
    Write-Host "  [CHUNK-REVIEW] $($completedChunks.Count)/$totalChunks chunks completed" -ForegroundColor $chunkStatusColor

    # ── 7. Fallback pass: retry failed chunks with any available agent ──
    $allLabels = $chunks | ForEach-Object { $_.Label }
    $failedLabels = @($allLabels | Where-Object { $_ -notin $completedChunks })
    if ($failedLabels.Count -gt 0 -and $completedChunks.Count -gt 0) {
        # Pick an agent that succeeded recently (it's warm and not rate-limited)
        $successChunk = $chunks | Where-Object { $_.Label -eq $completedChunks[-1] }
        $fallbackAgent = if ($successChunk) { $successChunk.Agent } else { $config.fallback_agent }

        Write-Host "  [FALLBACK] Retrying $($failedLabels.Count) failed chunk(s) with $fallbackAgent" -ForegroundColor Yellow

        foreach ($label in $failedLabels) {
            $chunk = $chunks | Where-Object { $_.Label -eq $label }
            $reqIds = ($chunk.Reqs | ForEach-Object { $_.id }) -join ", "

            $prompt = $templateRaw
            $prompt = $prompt.Replace("{{ITERATION}}", "$Iteration")
            $prompt = $prompt.Replace("{{HEALTH}}", "$Health")
            $prompt = $prompt.Replace("{{GSD_DIR}}", $GsdDir)
            $prompt = $prompt.Replace("{{REPO_ROOT}}", $RepoRoot)
            $prompt = $prompt.Replace("{{CHUNK_LABEL}}", $label)
            $prompt = $prompt.Replace("{{TOTAL_CHUNKS}}", "$totalChunks")
            $prompt = $prompt.Replace("{{CHUNK_COUNT}}", "$($chunk.Reqs.Count)")
            $prompt = $prompt.Replace("{{CHUNK_REQUIREMENT_IDS}}", $reqIds)
            $prompt = $prompt.Replace("{{BATCH_SIZE}}", "$CurrentBatchSize")
            $prompt = $prompt.Replace("{{INTERFACE_CONTEXT}}", $InterfaceContext)

            $logFile = Join-Path $GsdDir "logs\iter${Iteration}-1-chunk-${label}-fallback.log"
            $fbParams = @{
                Agent            = $fallbackAgent
                Prompt           = $prompt
                Phase            = "code-review"
                LogFile          = $logFile
                CurrentBatchSize = $CurrentBatchSize
                GsdDir           = $GsdDir
                MaxAttempts      = 1
            }
            if ($fallbackAgent -eq "claude") { $fbParams["AllowedTools"] = "Read,Write,Bash" }

            Invoke-WithRetry @fbParams | Out-Null

            $chunkFile = Join-Path $GsdDir "code-review\chunk-${label}.json"
            if (Test-Path $chunkFile) {
                $completedChunks += $label
                Write-Host "  [CHUNK-$label] Fallback completed" -ForegroundColor Green
            }

            Start-Sleep -Seconds $config.inter_chunk_cooldown_seconds
        }
        $result.ChunksCompleted = $completedChunks.Count
    }

    # ── 8. Merge chunk results into requirements-matrix.json + health-current.json ──
    Write-Host "  [CHUNK-MERGE] Merging $($completedChunks.Count) chunk results..." -ForegroundColor Cyan

    $statusUpdates = @{}  # id -> { status, evidence }
    $allBlockers = @()

    foreach ($label in $completedChunks) {
        $chunkFile = Join-Path $GsdDir "code-review\chunk-${label}.json"
        if (-not (Test-Path $chunkFile)) { continue }

        try {
            $raw = Get-Content $chunkFile -Raw
            # Strip markdown fences if agent wrapped output
            $raw = $raw -replace '(?s)```(?:json)?\s*', ''
            $raw = $raw -replace '(?s)\s*```', ''
            $chunkData = $raw | ConvertFrom-Json

            if ($chunkData.results) {
                foreach ($r in $chunkData.results) {
                    if ($r.id -and $r.status) {
                        $statusUpdates[$r.id] = @{
                            status   = $r.status
                            evidence = if ($r.evidence) { $r.evidence } else { "" }
                        }
                    }
                }
            }
            if ($chunkData.blockers) {
                $allBlockers += @($chunkData.blockers)
            }
        } catch {
            Write-Host "  [CHUNK-MERGE] Failed to parse chunk-${label}.json: $_" -ForegroundColor Red
        }
    }

    Write-Host "  [CHUNK-MERGE] Got $($statusUpdates.Count) status updates from $($completedChunks.Count) chunks" -ForegroundColor Cyan

    # Apply status updates to requirements-matrix.json
    if ($statusUpdates.Count -gt 0) {
        $matrix = Get-Content $matrixFile -Raw | ConvertFrom-Json
        $changed = 0
        $resolvedThisIter = @()

        foreach ($req in $matrix.requirements) {
            if ($statusUpdates.ContainsKey($req.id)) {
                $update = $statusUpdates[$req.id]
                $oldStatus = $req.status
                $newStatus = $update.status

                if ($oldStatus -ne $newStatus) {
                    $req.status = $newStatus
                    if ($update.evidence) { $req.satisfied_by = $update.evidence }
                    $changed++
                    $resolvedThisIter += "$($req.id): $oldStatus->$newStatus ($($update.evidence))"
                }
            }
        }

        # Write updated matrix
        $matrix | ConvertTo-Json -Depth 10 | Set-Content $matrixFile -Encoding UTF8
        $mergeColor = if ($changed -gt 0) { "Green" } else { "DarkGray" }
        Write-Host "  [CHUNK-MERGE] Updated $changed requirement statuses in matrix" -ForegroundColor $mergeColor

        # Recalculate health
        $satisfied = @($matrix.requirements | Where-Object { $_.status -eq "satisfied" }).Count
        $partial = @($matrix.requirements | Where-Object { $_.status -eq "partial" }).Count
        $notStarted = @($matrix.requirements | Where-Object { $_.status -eq "not_started" }).Count
        $total = $matrix.requirements.Count
        $newHealth = if ($total -gt 0) { [math]::Round(($satisfied + 0.5 * $partial) / $total * 100) } else { 0 }

        # Write health-current.json
        $healthData = @{
            health_score              = $newHealth
            satisfied                 = $satisfied
            partial                   = $partial
            not_started               = $notStarted
            total                     = $total
            iteration                 = $Iteration
            timestamp                 = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            formula                   = "(satisfied + 0.5 * partial) / total * 100"
            calc                      = "($satisfied + $($partial * 0.5)) / $total = $([math]::Round(($satisfied + 0.5 * $partial) / $total * 100, 2))% -> $newHealth%"
            status                    = if ($newHealth -ge 100) { "passed" } else { "in_progress" }
            delta                     = "$($newHealth - $Health) from previous (was $Health%)"
            resolved_this_iteration   = $resolvedThisIter
            remaining_blockers        = $allBlockers
            review_method             = "rate-limit-aware-chunked"
            chunks_completed          = $completedChunks.Count
            chunks_total              = $totalChunks
            waves                     = $numWaves
            agents_used               = ($availableAgents -join ", ")
        }
        $healthFile = Join-Path $GsdDir "health\health-current.json"
        $healthData | ConvertTo-Json -Depth 5 | Set-Content $healthFile -Encoding UTF8

        # Append to health-history.jsonl
        $historyFile = Join-Path $GsdDir "health\health-history.jsonl"
        ($healthData | ConvertTo-Json -Depth 5 -Compress) | Add-Content $historyFile -Encoding UTF8

        $healthColor = if ($newHealth -gt $Health) { "Green" } elseif ($newHealth -eq $Health) { "Yellow" } else { "Red" }
        Write-Host "  [CHUNK-MERGE] Health: $Health% -> $newHealth% (sat=$satisfied par=$partial ns=$notStarted)" -ForegroundColor $healthColor

        $result.NewHealth = $newHealth
    }

    # ── 9. Merge review markdown files ──
    $mergedReview = "# Code Review - Iteration $Iteration (Rate-Limit-Aware Chunked: $totalChunks chunks, $numWaves waves)`n`n"
    foreach ($chunk in $chunks) {
        $reviewFile = Join-Path $GsdDir "code-review\chunk-$($chunk.Label)-review.md"
        if (Test-Path $reviewFile) {
            $mergedReview += "## Chunk $($chunk.Label) [$($chunk.Agent), wave $($chunk.Wave)]`n" + (Get-Content $reviewFile -Raw) + "`n`n"
        }
    }
    $reviewCurrentFile = Join-Path $GsdDir "code-review\review-current.md"
    $mergedReview | Set-Content $reviewCurrentFile -Encoding UTF8

    $minRequired = [math]::Ceiling($totalChunks * $config.min_success_ratio)
    $result.Success = ($completedChunks.Count -ge $minRequired)

    $finalColor = if ($result.Success) { "Green" } else { "Red" }
    Write-Host "  [CHUNK-REVIEW] Final: $($completedChunks.Count)/$totalChunks chunks (need $minRequired). Success=$($result.Success)" -ForegroundColor $finalColor
    return $result
}
