<#
.SYNOPSIS
    GSD V3 Phase Orchestrator - 10-phase convergence loop, mode-aware, checkpoint/recovery
.DESCRIPTION
    The main convergence loop. Routes phases to the correct model (Sonnet or Codex Mini),
    manages iteration flow, speculative execution, and convergence detection.
    Fixes V2 issues:
    - V2 used CLI tools (claude, codex) via process spawning -- fragile, no structured output
    - V2 had separate convergence-loop.ps1 and pipeline.ps1 with duplicated logic
    - V2 did not enforce JSON output, causing parse failures
    - V2 had no local validation phase (went straight from execute to review)
    - V2 had no speculative execution (idle time between review and next iteration)
    - V2 had no budget enforcement (could run indefinitely)
    - V2 had no cache management
#>

# ============================================================
# MODULE-SCOPED STATE
# ============================================================

# Decomposition budget: prevents runaway sub-req explosion per iteration
$script:DecompBudget = @{
    AddedThisIteration = 0
    MaxPerIteration    = 20
    MaxDepth           = 4
}

# ============================================================
# MAIN ORCHESTRATOR
# ============================================================

function Start-V3Pipeline {
    <#
    .SYNOPSIS
        Main entry point for the V3 convergence pipeline.
    .PARAMETER RepoRoot
        Repository root path.
    .PARAMETER Mode
        Pipeline mode: greenfield, bug_fix, feature_update
    .PARAMETER Config
        Global config object (from global-config.json).
    .PARAMETER AgentMap
        Agent map object (from agent-map.json).
    .PARAMETER Scope
        Optional scope filter for bug_fix/feature_update modes.
    .PARAMETER NtfyTopic
        Notification topic.
    .PARAMETER StartIteration
        Resume from this iteration (for checkpoint recovery).
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$Mode = "greenfield",
        [PSObject]$Config,
        [PSObject]$AgentMap,
        [string]$Scope = "",
        [string]$NtfyTopic = "auto",
        [int]$StartIteration = 1
    )

    $pipelineStart = Get-Date
    $GsdDir = Join-Path $RepoRoot ".gsd"

    # Resolve V3 root from this module's location (lib/modules -> v3)
    $script:V3Root = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
    $script:SonnetModel = "claude-sonnet-4-6"

    Write-Host "`n============================================" -ForegroundColor Cyan
    Write-Host "  GSD V3 Pipeline - $Mode" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan

    # -- Resolve mode config --
    $modeConfig = $Config.pipeline_modes.$Mode
    if (-not $modeConfig) {
        Write-Host "  [XX] Unknown mode: $Mode" -ForegroundColor Red
        return @{ Success = $false; Error = "unknown_mode" }
    }

    $maxIterations = $modeConfig.max_iterations
    $batchSizeMax = $modeConfig.batch_size_max
    $budgetCap = $modeConfig.budget_cap_usd
    $phasesActive = $modeConfig.phases_active
    $phasesSkipped = if ($modeConfig.phases_skipped) { $modeConfig.phases_skipped } else { @() }

    Write-Host "  Max iterations: $maxIterations | Batch size: $batchSizeMax | Budget: `$$budgetCap" -ForegroundColor DarkGray
    Write-Host "  Phases: $($phasesActive -join ' -> ')" -ForegroundColor DarkGray

    # -- Initialize modules --
    Initialize-CostTracker -Mode $Mode -BudgetCap $budgetCap -GsdDir $GsdDir
    Initialize-Notifications -Topic $NtfyTopic -RepoRoot $RepoRoot

    # -- Start background monitors (heartbeat + command listener) --
    Start-HeartbeatMonitor -IntervalMinutes 10 -GsdDir $GsdDir
    Start-CommandListener -GsdDir $GsdDir

    # -- Pre-flight --
    Write-Host "`n--- Pre-flight ---" -ForegroundColor Yellow
    $preflight = Test-PreFlightV3 -RepoRoot $RepoRoot -GsdDir $GsdDir -Mode $Mode
    if (-not $preflight) {
        return @{ Success = $false; Error = "preflight_failed" }
    }

    # -- File inventory (FIRST THING -- everything depends on this) --
    Write-Host "`n--- File Inventory ---" -ForegroundColor Yellow
    $inventory = Build-FileInventory -RepoRoot $RepoRoot -GsdDir $GsdDir

    # -- Lock --
    New-GsdLock -GsdDir $GsdDir -Pipeline "v3" -Mode $Mode

    # -- Build spec context for cache prefix --
    Write-Host "`n--- Building Cache Prefix ---" -ForegroundColor Yellow
    Write-Host "  [DEBUG] Building spec context..." -ForegroundColor Magenta
    $specContext = Build-SpecContext -RepoRoot $RepoRoot -GsdDir $GsdDir -Inventory $inventory
    Write-Host "  [DEBUG] Spec context: $($specContext.Length) chars" -ForegroundColor Magenta
    Write-Host "  [DEBUG] Building blueprint context..." -ForegroundColor Magenta
    $blueprintContext = Build-BlueprintContext -RepoRoot $RepoRoot -GsdDir $GsdDir -Inventory $inventory
    Write-Host "  [DEBUG] Blueprint context: $($blueprintContext.Length) chars" -ForegroundColor Magenta

    $systemPromptPath = Join-Path $script:V3Root "prompts/shared/system-prompt.md"
    $systemPrompt = if (Test-Path $systemPromptPath) { Get-Content $systemPromptPath -Raw -Encoding UTF8 } else { "You are GSD, an autonomous software development system." }

    $cacheBlocks = @(
        @{ text = $systemPrompt; cache = $true; name = "system_prompt" }
        @{ text = $specContext; cache = $true; name = "spec_documents" }
        @{ text = $blueprintContext; cache = $true; name = "blueprint_manifest" }
    )

    # -- Regression baseline (for feature_update mode) --
    $baselineSnapshot = @{}
    if ($Mode -eq "feature_update") {
        $baselineSnapshot = Take-RequirementSnapshot -GsdDir $GsdDir
        Write-Host "  [BASELINE] Snapshot: $($baselineSnapshot.Count) requirements" -ForegroundColor DarkGray
    }

    # -- Phase 0: Cache Warm --
    if ("cache-warm" -in $phasesActive -and "cache-warm" -notin $phasesSkipped) {
        Write-Host "`n--- Phase 0: Cache Warm ---" -ForegroundColor Yellow
        $warmResult = Invoke-CacheWarmup -CacheBlocks $cacheBlocks
        if ($warmResult.Usage) {
            Add-ApiCallCost -Model $script:SonnetModel -Usage $warmResult.Usage -Phase "cache-warm"
        }
    }

    # -- Phase 1: Spec Gate --
    if ("spec-gate" -in $phasesActive -and "spec-gate" -notin $phasesSkipped) {
        Write-Host "`n--- Phase 1: Spec Gate ---" -ForegroundColor Yellow
        $specGateResult = Invoke-SpecGatePhase -GsdDir $GsdDir -RepoRoot $RepoRoot `
            -CacheBlocks $cacheBlocks -Config $Config -Mode $Mode -Inventory $inventory

        if ($specGateResult.Blocked) {
            Write-Host "  [BLOCKED] Spec gate blocked pipeline. Fix spec issues first." -ForegroundColor Red
            Remove-GsdLock -GsdDir $GsdDir
            return @{ Success = $false; Error = "spec_blocked"; Report = $specGateResult.Report }
        }
    }

    # -- Phase 1b: Spec Alignment (drift detection) --
    if ("spec-align" -in $phasesActive -and "spec-align" -notin $phasesSkipped) {
        $specAlignResult = Invoke-SpecAlignmentPhase -GsdDir $GsdDir -RepoRoot $RepoRoot `
            -CacheBlocks $cacheBlocks -Config $Config -Inventory $inventory

        if ($specAlignResult.Blocked) {
            Write-Host "  [BLOCKED] Spec alignment drift too high. Fix alignment first." -ForegroundColor Red
            Remove-GsdLock -GsdDir $GsdDir
            return @{ Success = $false; Error = "spec_alignment_blocked"; Report = $specAlignResult.Report }
        }
    }

    # -- Phase 1c: Figma Requirement Derivation (after spec gate, before iteration loop) --
    Write-Host "`n--- Phase 1c: Figma Requirement Derivation ---" -ForegroundColor Yellow
    $figmaDeriverPath = Join-Path $script:V3Root "lib/modules/figma-req-deriver.ps1"
    if (Test-Path $figmaDeriverPath) {
        if (-not (Get-Command Invoke-FigmaRequirementDerivation -ErrorAction SilentlyContinue)) {
            . $figmaDeriverPath
        }
        try {
            $figmaDerivation = Invoke-FigmaRequirementDerivation -RepoRoot $RepoRoot -GsdDir $GsdDir -Config $Config
            if ($figmaDerivation.MergedCount -gt 0) {
                Write-Host "  [FIGMA] Derived $($figmaDerivation.DerivedCount) requirements, merged $($figmaDerivation.MergedCount) new into matrix" -ForegroundColor Green
                Write-Host "  [FIGMA] Interfaces: $($figmaDerivation.Interfaces -join ', ')" -ForegroundColor DarkCyan
            } elseif (-not $figmaDerivation.Skipped) {
                Write-Host "  [FIGMA] All Figma requirements already in matrix (0 new)" -ForegroundColor DarkGray
            }
        } catch {
            Write-Host "  [WARN] Figma requirement derivation error: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "  [SKIP] figma-req-deriver.ps1 not found at $figmaDeriverPath" -ForegroundColor DarkGray
    }

    # -- Iteration Loop --
    $prevHealth = 0
    $currentHealth = 0
    $converged = $false
    $consecutiveZeroDelta = 0

    # Global iteration counter — persists across pipeline runs, unique per repo
    $globalIterStart = if ($env:GSD_GLOBAL_ITER_START) { [int]$env:GSD_GLOBAL_ITER_START } else { $StartIteration }
    $iterCounterFile = $env:GSD_ITER_COUNTER_FILE
    $iterLogDir = $env:GSD_ITER_LOG_DIR
    $repoName = if ($env:GSD_REPO_NAME) { $env:GSD_REPO_NAME } else { Split-Path $RepoRoot -Leaf }

    for ($iter = $StartIteration; $iter -le $maxIterations; $iter++) {
        # Calculate global iteration number (unique across all runs for this repo)
        $globalIter = $globalIterStart + ($iter - $StartIteration)

        Write-Host "`n========================================" -ForegroundColor Cyan
        Write-Host "  ITERATION $iter / $maxIterations  (Global #$globalIter)" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan

        # Per-iteration log file in central store
        $iterStartTime = Get-Date
        $iterLogData = @{
            global_iteration = $globalIter
            local_iteration  = $iter
            repo             = $repoName
            started_at       = $iterStartTime.ToString("o")
            run_id           = $env:GSD_RUN_ID
            phases           = @{}
        }

        try {  # Crash protection: one bad iteration should not kill the pipeline

        # Reset decomposition budget for this iteration
        $script:DecompBudget.AddedThisIteration = 0

        # Budget check -- estimate cost of upcoming iteration before starting
        # Estimated per-iteration cost: ~$0.15 Sonnet (research+plan+review+verify) + ~$0.05/req Codex execute
        $estimatedIterCost = 0.15 + ($batchSizeMax * 0.05)
        if (-not (Test-BudgetAvailable -EstimatedCost $estimatedIterCost)) {
            Write-Host "  [BUDGET] Budget exhausted (estimated next iteration: `$$([math]::Round($estimatedIterCost,2))). Halting." -ForegroundColor Red
            Send-GsdNotification -Title "GSD Budget Exceeded" -Message "Budget cap `$$budgetCap reached at iteration $iter" -Tags "warning"
            break
        }

        Save-Checkpoint -GsdDir $GsdDir -Iteration $iter -Phase "iteration-start" `
            -Health $prevHealth -BatchSize $batchSizeMax -Mode $Mode

        # -- Get requirements for this iteration --
        $scopedReqs = Get-ScopedRequirements -GsdDir $GsdDir -Scope $Scope
        if ($scopedReqs.Count -eq 0) {
            Write-Host "  No remaining requirements. Converged!" -ForegroundColor Green
            $converged = $true
            break
        }

        $batchReqs = Select-IntelligentBatch -Requirements $scopedReqs -BatchSize $batchSizeMax -GsdDir $GsdDir
        Write-Host "  Batch: $($batchReqs.Count) requirements" -ForegroundColor DarkGray

        # -- Research Phase --
        $researchOutput = $null
        if ("research" -in $phasesActive -and "research" -notin $phasesSkipped) {
            if (-not (Test-BudgetAvailable -EstimatedCost 0.10)) {
                Write-Host "  [BUDGET] Insufficient budget for Research phase. Halting." -ForegroundColor Red
                break
            }
            Write-Host "`n  --- Research ---" -ForegroundColor Yellow
            $researchOutput = Invoke-ResearchPhase -GsdDir $GsdDir -RepoRoot $RepoRoot `
                -CacheBlocks $cacheBlocks -Requirements $batchReqs -Iteration $iter `
                -Config $Config -Inventory $inventory
        }

        # -- Pre-Plan Decomposition (from Research output) --
        if ($researchOutput -and $researchOutput.decompose -and $researchOutput.decompose.Count -gt 0) {
            $matrixPath = Join-Path $GsdDir "requirements/requirements-matrix.json"
            $matrix = Get-Content $matrixPath -Raw | ConvertFrom-Json
            $reqs = [System.Collections.ArrayList]@($matrix.requirements)
            $totalAdded = 0
            $parentsDecomposed = @()

            foreach ($decomp in $researchOutput.decompose) {
                $parentId = $decomp.parent_id
                if (-not $decomp.sub_requirements -or $decomp.sub_requirements.Count -eq 0) { continue }

                # Decomposition budget: check depth
                $parentDepth = ($parentId -split '-').Count - 2
                if ($parentDepth -ge $script:DecompBudget.MaxDepth) {
                    Write-Host "    [BUDGET] Skipping decomposition of $parentId -- depth $parentDepth >= max $($script:DecompBudget.MaxDepth)" -ForegroundColor DarkYellow
                    continue
                }

                # Decomposition budget: check iteration limit
                $allowedCount = $script:DecompBudget.MaxPerIteration - $script:DecompBudget.AddedThisIteration
                if ($allowedCount -le 0) {
                    Write-Host "    [BUDGET] Decomposition budget exhausted ($($script:DecompBudget.AddedThisIteration)/$($script:DecompBudget.MaxPerIteration)) -- deferring $parentId" -ForegroundColor DarkYellow
                    continue
                }

                $parentsDecomposed += $parentId

                $parentReq = $reqs | Where-Object { ($_.id -eq $parentId) -or ($_.req_id -eq $parentId) }
                if ($parentReq) {
                    $parentReq.status = "satisfied"
                    $parentReq | Add-Member -NotePropertyName "decomposed" -NotePropertyValue $true -Force
                    $parentReq | Add-Member -NotePropertyName "notes" -NotePropertyValue "Research-decomposed into $($decomp.sub_requirements.Count) sub-reqs: $($decomp.reason)" -Force
                }

                $subsToAdd = $decomp.sub_requirements | Select-Object -First $allowedCount
                $deferred = $decomp.sub_requirements.Count - $subsToAdd.Count
                if ($deferred -gt 0) {
                    Write-Host "    [BUDGET] Taking $($subsToAdd.Count) of $($decomp.sub_requirements.Count) sub-reqs for $parentId, deferring $deferred" -ForegroundColor DarkYellow
                }

                foreach ($sub in $subsToAdd) {
                    $existing = $reqs | Where-Object { ($_.id -eq $sub.id) -or ($_.req_id -eq $sub.id) }
                    if ($existing) { continue }
                    $newReq = [PSCustomObject]@{
                        id = $sub.id
                        description = $sub.description
                        interface = if ($sub.interface) { $sub.interface } else { "backend" }
                        priority = if ($sub.priority) { $sub.priority } else { "medium" }
                        status = "not_started"
                        source = "research-decomposed"
                        parent_id = $parentId
                        category = "implementation"
                    }
                    $reqs.Add($newReq) | Out-Null
                    $totalAdded++
                    $script:DecompBudget.AddedThisIteration++
                }
            }

            if ($totalAdded -gt 0) {
                $matrix.requirements = $reqs.ToArray()
                # Safely update summary fields (may not exist on freshly seeded matrix)
                if (-not ($matrix.PSObject.Properties.Name -contains 'total')) {
                    $matrix | Add-Member -NotePropertyName 'total' -NotePropertyValue $reqs.Count -Force
                } else { $matrix.total = $reqs.Count }
                if (-not ($matrix.PSObject.Properties.Name -contains 'summary')) {
                    $matrix | Add-Member -NotePropertyName 'summary' -NotePropertyValue @{
                        satisfied = 0; partial = 0; not_started = $reqs.Count
                    } -Force
                } else {
                    $matrix.summary.satisfied = @($reqs | Where-Object { $_.status -eq "satisfied" }).Count
                    $matrix.summary.partial = @($reqs | Where-Object { $_.status -eq "partial" }).Count
                    $matrix.summary.not_started = @($reqs | Where-Object { $_.status -eq "not_started" }).Count
                }
                $matrix | ConvertTo-Json -Depth 10 | Set-Content $matrixPath -Encoding UTF8

                Write-Host "  [RESEARCH-DECOMPOSE] Split $($parentsDecomposed.Count) large reqs into $totalAdded sub-reqs (budget: $($script:DecompBudget.AddedThisIteration)/$($script:DecompBudget.MaxPerIteration))" -ForegroundColor Cyan
                foreach ($parentId in $parentsDecomposed) { Write-Host "    Parent: $parentId" -ForegroundColor DarkCyan }

                # Replace decomposed parents with their sub-reqs in current batch
                $batchReqs = @($batchReqs | Where-Object {
                    $rid = if ($_.id) { $_.id } else { $_.req_id }
                    $rid -notin $parentsDecomposed
                })

                # Add sub-reqs to current batch so they go through Plan+Execute THIS iteration
                $newSubReqs = @($reqs | Where-Object { $_.source -eq "research-decomposed" -and $_.status -eq "not_started" -and $_.parent_id -in $parentsDecomposed })
                $batchReqs = @($batchReqs) + @($newSubReqs)
                Write-Host "  [RESEARCH-DECOMPOSE] Batch now has $($batchReqs.Count) reqs (replaced parents with sub-reqs for same-iteration processing)" -ForegroundColor Cyan
            }
        }

        # Also check research size_estimate for requirements Sonnet didn't explicitly decompose
        if ($researchOutput -and $researchOutput.findings) {
            $needsSplit = @()
            foreach ($finding in $researchOutput.findings) {
                if ($finding.size_estimate -and $finding.size_estimate.needs_decomposition -eq $true) {
                    $rid = $finding.req_id
                    # Only flag if not already decomposed above
                    $alreadyDone = if ($researchOutput.decompose) { $researchOutput.decompose | Where-Object { $_.parent_id -eq $rid } } else { $null }
                    if (-not $alreadyDone) {
                        $needsSplit += $rid
                        Write-Host "  [WARN] $rid flagged needs_decomposition but Research didn't split it -- ENFORCE-DECOMPOSE will catch it post-Plan" -ForegroundColor DarkYellow
                    }
                }
            }
        }

        # -- Pre-Plan: Force-decompose any previously truncated requirements --
        $matrixPath = Join-Path $GsdDir "requirements/requirements-matrix.json"
        $needsDecomp = @($batchReqs | Where-Object { $_.needs_decomposition -eq $true })
        if ($needsDecomp.Count -gt 0) {
            Write-Host "  [PRE-DECOMPOSE] $($needsDecomp.Count) reqs flagged for decomposition (previously truncated)" -ForegroundColor Yellow
            $matrix = Get-Content $matrixPath -Raw | ConvertFrom-Json
            $reqsList = [System.Collections.ArrayList]@($matrix.requirements)
            $totalAdded = 0
            foreach ($tReq in $needsDecomp) {
                $tId = if ($tReq.id) { $tReq.id } else { $tReq.req_id }

                # Decomposition budget: check depth
                $tDepth = ($tId -split '-').Count - 2
                if ($tDepth -ge $script:DecompBudget.MaxDepth) {
                    Write-Host "    [BUDGET] Skipping pre-decompose of $tId -- depth $tDepth >= max $($script:DecompBudget.MaxDepth)" -ForegroundColor DarkYellow
                    continue
                }
                # Decomposition budget: check iteration limit
                if ($script:DecompBudget.AddedThisIteration -ge $script:DecompBudget.MaxPerIteration) {
                    Write-Host "    [BUDGET] Pre-decompose budget exhausted -- deferring $tId" -ForegroundColor DarkYellow
                    continue
                }

                # Create 2 sub-reqs: backend + frontend (simple split since we don't have plan details yet)
                foreach ($layer in @("backend", "frontend")) {
                    $subId = "$tId-$layer"
                    $existing = $reqsList | Where-Object { ($_.id -eq $subId) -or ($_.req_id -eq $subId) }
                    if (-not $existing) {
                        if ($script:DecompBudget.AddedThisIteration -ge $script:DecompBudget.MaxPerIteration) {
                            Write-Host "    [BUDGET] Pre-decompose budget hit during $tId sub-req creation" -ForegroundColor DarkYellow
                            break
                        }
                        $newReq = [PSCustomObject]@{
                            id = $subId; description = "$($tReq.description) [$layer layer]"
                            interface = $layer; priority = if ($tReq.priority) { $tReq.priority } else { "medium" }
                            status = "not_started"; source = "truncation-decomposed"; parent_id = $tId; category = "implementation"
                        }
                        $reqsList.Add($newReq) | Out-Null
                        $totalAdded++
                        $script:DecompBudget.AddedThisIteration++
                        Write-Host "    [SUB] $subId -- $layer" -ForegroundColor DarkCyan
                    }
                }
                # Mark parent as decomposed
                $parentReq = $reqsList | Where-Object { ($_.id -eq $tId) -or ($_.req_id -eq $tId) }
                if ($parentReq) {
                    $parentReq.status = "satisfied"
                    $parentReq | Add-Member -NotePropertyName "decomposed" -NotePropertyValue $true -Force
                }
            }
            if ($totalAdded -gt 0) {
                $matrix.requirements = $reqsList.ToArray()
                $matrix.total = $reqsList.Count
                $matrix.summary.satisfied = @($reqsList | Where-Object { $_.status -eq "satisfied" }).Count
                $matrix.summary.not_started = @($reqsList | Where-Object { $_.status -eq "not_started" }).Count
                $matrix | ConvertTo-Json -Depth 10 | Set-Content $matrixPath -Encoding UTF8
                Write-Host "  [PRE-DECOMPOSE] Added $totalAdded sub-reqs, removed $($needsDecomp.Count) truncated parents from batch" -ForegroundColor Cyan
            }
            # Remove decomposed parents from batch
            $decompIds = @($needsDecomp | ForEach-Object { if ($_.id) { $_.id } else { $_.req_id } })
            $batchReqs = @($batchReqs | Where-Object {
                $rid = if ($_.id) { $_.id } else { $_.req_id }
                $rid -notin $decompIds
            })
            if ($batchReqs.Count -eq 0) {
                Write-Host "  [PRE-DECOMPOSE] All batch reqs decomposed. Next iteration picks up sub-reqs." -ForegroundColor Cyan
                continue
            }
        }

        # -- Plan Phase --
        if (-not (Test-BudgetAvailable -EstimatedCost 0.10)) {
            Write-Host "  [BUDGET] Insufficient budget for Plan phase. Halting." -ForegroundColor Red
            break
        }
        Write-Host "`n  --- Plan ---" -ForegroundColor Yellow
        $planOutput = Invoke-PlanPhase -GsdDir $GsdDir -RepoRoot $RepoRoot `
            -CacheBlocks $cacheBlocks -Requirements $batchReqs -Iteration $iter `
            -Research $researchOutput -Config $Config -Mode $Mode -Inventory $inventory

        if (-not $planOutput -or -not $planOutput.Plans) {
            Write-Host "  [WARN] Plan phase produced no output, skipping iteration" -ForegroundColor DarkYellow
            continue
        }

        # -- Handle Decomposed Requirements --
        if ($planOutput.decomposed -and $planOutput.decomposed.Count -gt 0) {
            $matrixPath = Join-Path $GsdDir "requirements/requirements-matrix.json"
            $matrix = Get-Content $matrixPath -Raw | ConvertFrom-Json
            $reqs = [System.Collections.ArrayList]@($matrix.requirements)
            $totalAdded = 0
            $parentsDecomposed = @()

            foreach ($decomp in $planOutput.decomposed) {
                $parentId = $decomp.parent_id

                # Decomposition budget: check depth
                $planDepth = ($parentId -split '-').Count - 2
                if ($planDepth -ge $script:DecompBudget.MaxDepth) {
                    Write-Host "    [BUDGET] Skipping plan-decompose of $parentId -- depth $planDepth >= max $($script:DecompBudget.MaxDepth)" -ForegroundColor DarkYellow
                    continue
                }
                # Decomposition budget: check iteration limit
                $allowedCount = $script:DecompBudget.MaxPerIteration - $script:DecompBudget.AddedThisIteration
                if ($allowedCount -le 0) {
                    Write-Host "    [BUDGET] Plan-decompose budget exhausted -- deferring $parentId" -ForegroundColor DarkYellow
                    continue
                }

                $parentsDecomposed += $parentId

                # Mark parent as decomposed (not executed directly)
                $parentReq = $reqs | Where-Object { ($_.id -eq $parentId) -or ($_.req_id -eq $parentId) }
                if ($parentReq) {
                    $parentReq.status = "satisfied"
                    $parentReq | Add-Member -NotePropertyName "decomposed" -NotePropertyValue $true -Force
                    $parentReq | Add-Member -NotePropertyName "notes" -NotePropertyValue "Decomposed into $($decomp.sub_requirements.Count) sub-requirements" -Force
                }

                # Add sub-requirements to matrix (budget-limited)
                $subsToAdd = $decomp.sub_requirements | Select-Object -First $allowedCount
                foreach ($sub in $subsToAdd) {
                    # Skip if already exists
                    $existing = $reqs | Where-Object { ($_.id -eq $sub.id) -or ($_.req_id -eq $sub.id) }
                    if ($existing) { continue }

                    $newReq = [PSCustomObject]@{
                        id = $sub.id
                        description = $sub.description
                        interface = $sub.interface
                        priority = if ($sub.priority) { $sub.priority } else { "medium" }
                        status = "not_started"
                        source = "decomposed"
                        parent_id = $parentId
                        category = if ($sub.category) { $sub.category } else { "implementation" }
                    }
                    $reqs.Add($newReq) | Out-Null
                    $totalAdded++
                    $script:DecompBudget.AddedThisIteration++
                }
            }

            if ($totalAdded -gt 0) {
                # Update matrix
                $matrix.requirements = $reqs.ToArray()
                $matrix.total = $reqs.Count
                $satisfied = @($reqs | Where-Object { $_.status -eq "satisfied" }).Count
                $partial = @($reqs | Where-Object { $_.status -eq "partial" }).Count
                $matrix.summary.satisfied = $satisfied
                $matrix.summary.partial = $partial
                $matrix.summary.not_started = @($reqs | Where-Object { $_.status -eq "not_started" }).Count
                $matrix | ConvertTo-Json -Depth 10 | Set-Content $matrixPath -Encoding UTF8

                Write-Host "  [DECOMPOSE] Split $($parentsDecomposed.Count) large requirements into $totalAdded sub-requirements" -ForegroundColor Cyan
                Write-Host "  [DECOMPOSE] Parents: $($parentsDecomposed -join ', ')" -ForegroundColor DarkCyan

                # Remove plans for decomposed parents -- they'll be picked up as sub-reqs next iteration
                $planOutput.plans = @($planOutput.plans | Where-Object {
                    $rid = if ($_.req_id) { $_.req_id } else { $_.id }
                    $rid -notin $parentsDecomposed
                })

                # If all plans were decomposed, skip to next iteration to pick up sub-reqs
                if ($planOutput.plans.Count -eq 0) {
                    Write-Host "  [DECOMPOSE] All requirements decomposed. Next iteration will process sub-requirements." -ForegroundColor Cyan
                    continue
                }
            }
        }

        # -- Proactive Decomposition: split large Figma screen reqs into sub-components --
        # Screen pages often produce 10-16K+ tokens. Split into: hooks+types, page component, sub-components
        $proactiveDecompCount = 0
        $proactivePlans = @()
        foreach ($plan in $planOutput.plans) {
            $rid = if ($plan.req_id) { $plan.req_id } else { $plan.id }
            $isFigmaScreen = ($rid -match 'FIGMA-.*-SCR-')
            $createFiles = if ($plan.files_to_create) { @($plan.files_to_create) } else { @() }

            # Check if this is a single large screen file estimated to exceed 12K tokens
            $singleLargeFile = $false
            if ($isFigmaScreen -and $createFiles.Count -eq 1) {
                $est = 0
                if ($createFiles[0].estimated_tokens) { $est = $createFiles[0].estimated_tokens }
                if ($est -gt 12000 -or $createFiles[0].path -match 'Page\.tsx$') {
                    $singleLargeFile = $true
                }
            }
            # Also flag screen reqs that were previously truncated
            $prevTruncated = $false
            $truncTrackerPath = Join-Path $GsdDir "requirements/truncation-tracker.json"
            if (Test-Path $truncTrackerPath) {
                try {
                    $ttCheck = Get-Content $truncTrackerPath -Raw | ConvertFrom-Json
                    if ($ttCheck.PSObject.Properties.Name -contains $rid) { $prevTruncated = $true }
                } catch {}
            }

            if (($singleLargeFile -or $prevTruncated) -and ($rid -split '-').Count -le 6) {
                # Split: create plan variants for hooks+types vs page component
                $filePath = $createFiles[0].path
                $fileDir = [System.IO.Path]::GetDirectoryName($filePath) -replace '\\','/'
                $fileName = [System.IO.Path]::GetFileNameWithoutExtension($filePath)

                # Sub-plan 1: hooks + types + API service (supporting files)
                $hooksPlan = $plan.PSObject.Copy()
                $hooksPlan | Add-Member -NotePropertyName "req_id" -NotePropertyValue "$rid-HOOKS" -Force
                $hooksPlan | Add-Member -NotePropertyName "files_to_create" -NotePropertyValue @(
                    @{ path = "$fileDir/hooks/use${fileName}Data.ts"; description = "Data fetching hook with React Query for $fileName — all API calls, loading/error states, mutations"; type = "create" }
                    @{ path = "$fileDir/types/${fileName}Types.ts"; description = "TypeScript interfaces and types for $fileName"; type = "create" }
                ) -Force

                # Sub-plan 2: page component (imports hooks, renders UI)
                $pagePlan = $plan.PSObject.Copy()
                $pagePlan | Add-Member -NotePropertyName "req_id" -NotePropertyValue "$rid-PAGE" -Force
                # Keep original files_to_create but add note that hooks are separate
                $pagePlan | Add-Member -NotePropertyName "notes" -NotePropertyValue "Page component only — data hooks are in separate use${fileName}Data.ts hook. Import and use the hook. Keep the page component focused on UI rendering." -Force

                # Add sub-requirements to matrix
                $matrixPath2 = Join-Path $GsdDir "requirements/requirements-matrix.json"
                $matrix2 = Get-Content $matrixPath2 -Raw | ConvertFrom-Json
                $reqsList2 = [System.Collections.ArrayList]@($matrix2.requirements)
                foreach ($subId in @("$rid-HOOKS", "$rid-PAGE")) {
                    $existing2 = $reqsList2 | Where-Object { $_.id -eq $subId }
                    if (-not $existing2) {
                        $parentReq2 = $reqsList2 | Where-Object { ($_.id -eq $rid) -or ($_.req_id -eq $rid) }
                        $desc2 = if ($parentReq2) { $parentReq2.description } else { $rid }
                        $layer2 = if ($subId -match 'HOOKS') { "hooks+types" } else { "page component" }
                        $reqsList2.Add([PSCustomObject]@{
                            id = $subId; description = "$desc2 [$layer2]"
                            interface = "web"; priority = "high"; status = "not_started"
                            source = "proactive-decompose"; parent_id = $rid; category = "figma-screen"
                        }) | Out-Null
                    }
                }
                # Mark parent satisfied
                $parentR = $reqsList2 | Where-Object { ($_.id -eq $rid) -or ($_.req_id -eq $rid) }
                if ($parentR) {
                    $parentR.status = "satisfied"
                    $parentR | Add-Member -NotePropertyName "decomposed" -NotePropertyValue $true -Force
                }
                $matrix2.requirements = $reqsList2.ToArray()
                $matrix2 | ConvertTo-Json -Depth 10 | Set-Content $matrixPath2 -Encoding UTF8

                $proactivePlans += $hooksPlan
                $proactivePlans += $pagePlan
                $proactiveDecompCount++
                Write-Host "  [PROACTIVE-DECOMPOSE] $rid split into $rid-HOOKS + $rid-PAGE (prevent truncation)" -ForegroundColor Magenta
            } else {
                $proactivePlans += $plan
            }
        }
        if ($proactiveDecompCount -gt 0) {
            Write-Host "  [PROACTIVE-DECOMPOSE] Split $proactiveDecompCount large screen reqs to prevent truncation" -ForegroundColor Magenta
            $planOutput.plans = $proactivePlans
        }

        # -- Enforce Decomposition (post-plan check) --
        # If Sonnet didn't decompose but plan has requirements with too many files, force decomposition
        $plansToDecompose = @()
        $plansToKeep = @()
        foreach ($plan in $planOutput.plans) {
            $fileCount = 0
            if ($plan.files_to_create) { $fileCount += @($plan.files_to_create).Count }
            if ($plan.files_to_modify) { $fileCount += @($plan.files_to_modify).Count }
            $estTokens = 0
            if ($plan.batch_summary -and $plan.batch_summary.estimated_total_output_tokens) {
                $estTokens = $plan.batch_summary.estimated_total_output_tokens
            } elseif ($plan.files_to_create) {
                foreach ($f in $plan.files_to_create) {
                    if ($f.estimated_tokens) { $estTokens += $f.estimated_tokens }
                }
            }
            # Fallback: if no token estimate available, use file count heuristic (3K tokens per file)
            if ($estTokens -eq 0 -and $fileCount -gt 0) {
                $estTokens = $fileCount * 3000
            }
            $rid = if ($plan.req_id) { $plan.req_id } else { $plan.id }

            # Prevent infinite decomposition: if req ID has 5+ hyphens, it's already deeply decomposed — let it through
            $decompositionDepth = ($rid -split '-').Count - 2  # CL-144 = depth 0, CL-144-CORE = depth 1, etc.
            $maxFiles = if ($decompositionDepth -ge 4) { 10 } elseif ($decompositionDepth -ge 3) { 8 } else { 5 }
            $maxTokens = if ($decompositionDepth -ge 4) { 16000 } elseif ($decompositionDepth -ge 3) { 12000 } else { 8000 }

            if (($fileCount -ge $maxFiles -or $estTokens -gt $maxTokens) -and $decompositionDepth -lt 6) {
                Write-Host "  [ENFORCE-DECOMPOSE] $rid has $fileCount files, ~$estTokens tokens -- too large for single Codex call" -ForegroundColor Yellow
                $plansToDecompose += $plan
            } else {
                $plansToKeep += $plan
            }
        }

        if ($plansToDecompose.Count -gt 0) {
            $matrixPath = Join-Path $GsdDir "requirements/requirements-matrix.json"
            $matrix = Get-Content $matrixPath -Raw | ConvertFrom-Json
            $reqs = [System.Collections.ArrayList]@($matrix.requirements)
            $totalAdded = 0

            foreach ($plan in $plansToDecompose) {
                $rid = if ($plan.req_id) { $plan.req_id } else { $plan.id }

                # Decomposition budget: check depth
                $eDepth = ($rid -split '-').Count - 2
                if ($eDepth -ge $script:DecompBudget.MaxDepth) {
                    Write-Host "    [BUDGET] Skipping enforce-decompose of $rid -- depth $eDepth >= max $($script:DecompBudget.MaxDepth)" -ForegroundColor DarkYellow
                    $plansToKeep += $plan
                    continue
                }
                # Decomposition budget: check iteration limit
                if ($script:DecompBudget.AddedThisIteration -ge $script:DecompBudget.MaxPerIteration) {
                    Write-Host "    [BUDGET] Enforce-decompose budget exhausted -- keeping $rid as-is" -ForegroundColor DarkYellow
                    $plansToKeep += $plan
                    continue
                }

                # Auto-split: group files by layer (backend, frontend, database, docs/scripts)
                $groups = @{ backend = @(); frontend = @(); database = @(); other = @() }
                $allFiles = @()
                if ($plan.files_to_create) { $allFiles += @($plan.files_to_create) }
                if ($plan.files_to_modify) {
                    foreach ($fm in @($plan.files_to_modify)) {
                        $allFiles += [PSCustomObject]@{ path = $fm.path; description = $fm.changes; type = "modify" }
                    }
                }
                foreach ($f in $allFiles) {
                    $p = if ($f.path) { $f.path } else { "" }
                    if ($p -match "src/web/|src/mcp-admin/|\.tsx?$|\.css$") { $groups.frontend += $f }
                    elseif ($p -match "backend/|src/Server/|\.cs$|\.csproj$") { $groups.backend += $f }
                    elseif ($p -match "database/|\.sql$") { $groups.database += $f }
                    else { $groups.other += $f }
                }

                $subIdx = 1
                $parentReq = $reqs | Where-Object { ($_.id -eq $rid) -or ($_.req_id -eq $rid) }
                $parentDesc = if ($parentReq) { $parentReq.description } else { $rid }

                foreach ($layer in @("backend", "frontend", "database", "other")) {
                    if ($groups[$layer].Count -eq 0) { continue }
                    if ($script:DecompBudget.AddedThisIteration -ge $script:DecompBudget.MaxPerIteration) {
                        Write-Host "    [BUDGET] Enforce-decompose budget hit during $rid sub-req creation" -ForegroundColor DarkYellow
                        break
                    }
                    $subId = "$rid-$subIdx"
                    $existing = $reqs | Where-Object { ($_.id -eq $subId) -or ($_.req_id -eq $subId) }
                    if (-not $existing) {
                        $fileList = ($groups[$layer] | ForEach-Object { $_.path }) -join ", "
                        $newReq = [PSCustomObject]@{
                            id = $subId
                            description = "$parentDesc [$layer layer: $($groups[$layer].Count) files]"
                            interface = $layer
                            priority = if ($parentReq -and $parentReq.priority) { $parentReq.priority } else { "medium" }
                            status = "not_started"
                            source = "auto-decomposed"
                            parent_id = $rid
                            category = "implementation"
                            files = $fileList
                        }
                        $reqs.Add($newReq) | Out-Null
                        $totalAdded++
                        $script:DecompBudget.AddedThisIteration++
                        Write-Host "    [SUB] $subId -- $layer ($($groups[$layer].Count) files)" -ForegroundColor DarkCyan
                    }
                    $subIdx++
                }

                # Mark parent as decomposed
                if ($parentReq) {
                    $parentReq.status = "satisfied"
                    $parentReq | Add-Member -NotePropertyName "decomposed" -NotePropertyValue $true -Force
                    $parentReq | Add-Member -NotePropertyName "notes" -NotePropertyValue "Auto-decomposed into $($subIdx-1) sub-requirements (>=3 files or >8K tokens)" -Force
                }
            }

            if ($totalAdded -gt 0) {
                $matrix.requirements = $reqs.ToArray()
                # Safely update summary fields (may not exist on freshly seeded matrix)
                if (-not ($matrix.PSObject.Properties.Name -contains 'total')) {
                    $matrix | Add-Member -NotePropertyName 'total' -NotePropertyValue $reqs.Count -Force
                } else { $matrix.total = $reqs.Count }
                if (-not ($matrix.PSObject.Properties.Name -contains 'summary')) {
                    $matrix | Add-Member -NotePropertyName 'summary' -NotePropertyValue @{
                        satisfied = 0; partial = 0; not_started = $reqs.Count
                    } -Force
                } else {
                    $matrix.summary.satisfied = @($reqs | Where-Object { $_.status -eq "satisfied" }).Count
                    $matrix.summary.partial = @($reqs | Where-Object { $_.status -eq "partial" }).Count
                    $matrix.summary.not_started = @($reqs | Where-Object { $_.status -eq "not_started" }).Count
                }
                $matrix | ConvertTo-Json -Depth 10 | Set-Content $matrixPath -Encoding UTF8
                Write-Host "  [ENFORCE-DECOMPOSE] Auto-split $($plansToDecompose.Count) reqs into $totalAdded sub-reqs (budget: $($script:DecompBudget.AddedThisIteration)/$($script:DecompBudget.MaxPerIteration))" -ForegroundColor Cyan
            }

            # Only keep plans for non-decomposed requirements
            $planOutput.plans = $plansToKeep
            if ($planOutput.plans.Count -eq 0) {
                Write-Host "  [ENFORCE-DECOMPOSE] All reqs decomposed. Next iteration picks up sub-reqs." -ForegroundColor Cyan
                continue
            }
        }

        # -- Execute Phase (Two-Stage: Skeleton then Fill) --
        # Execute is the most expensive phase: estimate $0.05/req for Codex Mini
        $execEstimate = $batchReqs.Count * 0.05
        if (-not (Test-BudgetAvailable -EstimatedCost $execEstimate)) {
            Write-Host "  [BUDGET] Insufficient budget for Execute phase (~`$$([math]::Round($execEstimate,2)) for $($batchReqs.Count) reqs). Halting." -ForegroundColor Red
            break
        }
        $executeResults = @{}
        $skeletonResults = $null
        $usesTwoStage = $modeConfig.two_stage_execute

        if ($usesTwoStage -and "execute-skeleton" -in $phasesActive -and "execute-skeleton" -notin $phasesSkipped) {
            Write-Host "`n  --- Execute: Skeleton ---" -ForegroundColor Yellow
            $skeletonResults = Invoke-ExecutePhase -GsdDir $GsdDir -RepoRoot $RepoRoot `
                -Plans $planOutput.Plans -Stage "skeleton" -Config $Config -Inventory $inventory

            # If ALL skeleton calls failed (e.g. rate limited), skip fill phase entirely
            if ($skeletonResults -and $skeletonResults.Completed -eq 0 -and $skeletonResults.Failed -gt 0) {
                Write-Host "  [SKIP] All skeleton calls failed ($($skeletonResults.Failed) failures). Skipping fill phase." -ForegroundColor Red
                $executeResults = $skeletonResults
                # Skip fill -- go to local validate
                continue
            }
        }

        Write-Host "`n  --- Execute: Fill ---" -ForegroundColor Yellow
        $fillParams = @{
            GsdDir    = $GsdDir
            RepoRoot  = $RepoRoot
            Plans     = $planOutput.Plans
            Stage     = "fill"
            Config    = $Config
            Inventory = $inventory
        }
        if ($skeletonResults) { $fillParams["SkeletonResults"] = $skeletonResults }
        $executeResults = Invoke-ExecutePhase @fillParams

        # -- Post-Fill Truncation Detection: track truncation count per req, escalate or decompose --
        if ($executeResults -and $executeResults.Results) {
            # Load/create truncation tracker
            $truncTrackerPath = Join-Path $GsdDir "requirements/truncation-tracker.json"
            $truncTracker = @{}
            if (Test-Path $truncTrackerPath) {
                try {
                    $ttData = Get-Content $truncTrackerPath -Raw | ConvertFrom-Json
                    foreach ($prop in $ttData.PSObject.Properties) { $truncTracker[$prop.Name] = [int]$prop.Value }
                } catch {}
            }

            $truncatedReqs = @()
            foreach ($reqId in $executeResults.Results.Keys) {
                $r = $executeResults.Results[$reqId]
                if ($r.StopReason -eq "max_tokens" -or $r.FinishReason -eq "max_tokens" -or ($r.Usage -and $r.Usage.output_tokens -ge 16000)) {
                    $truncatedReqs += $reqId
                    if (-not $truncTracker.ContainsKey($reqId)) { $truncTracker[$reqId] = 0 }
                    $truncTracker[$reqId]++
                }
            }

            # Save truncation tracker
            $truncTracker | ConvertTo-Json -Depth 3 | Set-Content $truncTrackerPath -Encoding UTF8

            if ($truncatedReqs.Count -gt 0) {
                Write-Host "  [TRUNCATION] $($truncatedReqs.Count) reqs hit token limit: $($truncatedReqs -join ', ')" -ForegroundColor Red

                # Immediate escalation: ALL truncated reqs get routed to larger model on very next iteration
                # (Don't wait for 2nd truncation — that wastes an entire iteration)
                $escalateReqs = @($truncatedReqs)
                $decompReqs = @($truncatedReqs | Where-Object { $truncTracker[$_] -ge 2 })

                if ($escalateReqs.Count -gt 0) {
                    Write-Host "  [TRUNCATION-ESCALATE] $($escalateReqs.Count) reqs truncated -- flagged for larger model (DeepSeek/Claude) on next iteration: $($escalateReqs -join ', ')" -ForegroundColor Yellow
                }

                $matrixPath = Join-Path $GsdDir "requirements/requirements-matrix.json"
                $matrix = Get-Content $matrixPath -Raw | ConvertFrom-Json
                foreach ($tReqId in $truncatedReqs) {
                    $req = $matrix.requirements | Where-Object { ($_.id -eq $tReqId) -or ($_.req_id -eq $tReqId) }
                    if ($req -and -not $req.decomposed) {
                        $req.status = "not_started"
                        # Immediate escalation: flag for larger model on very next iteration
                        $req | Add-Member -NotePropertyName "use_large_model" -NotePropertyValue $true -Force
                        $req | Add-Member -NotePropertyName "needs_decomposition" -NotePropertyValue $true -Force
                        $req | Add-Member -NotePropertyName "notes" -NotePropertyValue "Truncated at 16K tokens (attempt $($truncTracker[$tReqId])) -- route to DeepSeek/Claude + decompose next iteration" -Force
                    }
                }
                $matrix | ConvertTo-Json -Depth 10 | Set-Content $matrixPath -Encoding UTF8
            }
        }

        # -- LLM Pre-Validate Review+Fix (Sonnet fixes code BEFORE local build) --
        Write-Host "`n  --- LLM Pre-Validate Fix ---" -ForegroundColor Cyan
        $fixerScript = Join-Path $script:V3Root "scripts/gsd-validation-fixer.ps1"
        if (Test-Path $fixerScript) {
            $allReqIds = @($planOutput.Plans | ForEach-Object { if ($_.req_id) { $_.req_id } else { $_.id } })
            try {
                & $fixerScript -RepoRoot $RepoRoot -RequirementIds $allReqIds -MaxAttempts 3 -PreValidate
            } catch {
                Write-Host "    [WARN] Pre-validate fixer error: $($_.Exception.Message)" -ForegroundColor DarkYellow
            }
        }

        # -- Local Validate Phase (confirmation check after LLM fix) --
        Write-Host "`n  --- Local Validate ---" -ForegroundColor Yellow
        $validateResults = Invoke-LocalValidatePhase -GsdDir $GsdDir -RepoRoot $RepoRoot `
            -ExecuteResults $executeResults -Plans $planOutput.Plans

        # If validation still failed, run targeted fixer on specific failures
        $failCount = if ($validateResults -and $validateResults.FailItems) { @($validateResults.FailItems).Count } else { 0 }
        if ($failCount -gt 0) {
            Write-Host "`n  --- Validation Fixer (targeted fix for $failCount remaining failures) ---" -ForegroundColor Cyan
            $failedReqIds = @($validateResults.FailItems | ForEach-Object { $_.ReqId })
            if (Test-Path $fixerScript) {
                try {
                    & $fixerScript -RepoRoot $RepoRoot -RequirementIds $failedReqIds -MaxAttempts 5
                } catch {
                    Write-Host "    [WARN] Validation fixer error: $($_.Exception.Message)" -ForegroundColor DarkYellow
                }
                # Re-validate after fixes
                Write-Host "`n  --- Re-Validate (post-fix) ---" -ForegroundColor Yellow
                $validateResults = Invoke-LocalValidatePhase -GsdDir $GsdDir -RepoRoot $RepoRoot `
                    -ExecuteResults $executeResults -Plans $planOutput.Plans
                $failCount = if ($validateResults -and $validateResults.FailItems) { @($validateResults.FailItems).Count } else { 0 }
                Write-Host "    Post-fix: $failCount items still failing" -ForegroundColor $(if ($failCount -eq 0) { "Green" } else { "Yellow" })
            }
        }

        # -- Update Fail Tracker (deprioritize repeatedly failing requirements) --
        if ($validateResults -and $validateResults.FailItems) {
            $failTrackerPath = Join-Path $GsdDir "requirements/fail-tracker.json"
            $failTracker = @{}
            if (Test-Path $failTrackerPath) {
                try {
                    $ftData = Get-Content $failTrackerPath -Raw | ConvertFrom-Json
                    foreach ($prop in $ftData.PSObject.Properties) { $failTracker[$prop.Name] = [int]$prop.Value }
                } catch {}
            }
            foreach ($failItem in $validateResults.FailItems) {
                $rid = $failItem.ReqId
                if (-not $failTracker.ContainsKey($rid)) { $failTracker[$rid] = 0 }
                $failTracker[$rid]++
            }
            # Also decrement (reward) items that passed -- they should stay prioritized
            if ($validateResults.PassItems) {
                foreach ($passItem in $validateResults.PassItems) {
                    $rid = $passItem.ReqId
                    if ($failTracker.ContainsKey($rid) -and $failTracker[$rid] -gt 0) {
                        $failTracker[$rid] = [math]::Max(0, $failTracker[$rid] - 1)
                    }
                }
            }
            $failTracker | ConvertTo-Json -Depth 3 | Set-Content $failTrackerPath -Encoding UTF8
            $highFailReqs = @($failTracker.GetEnumerator() | Where-Object { $_.Value -ge 3 })
            if ($highFailReqs.Count -gt 0) {
                Write-Host "  [DEPRIORITIZE] $($highFailReqs.Count) reqs failed 3+ times -- moved to back of queue" -ForegroundColor DarkYellow
            }
        }

        # -- Phase 5b: Design System Gate (between local-validate and review) --
        $dsgConfig = $Config.design_system_gate
        if ($dsgConfig -and $dsgConfig.enabled) {
            Write-Host "`n  --- Design System Gate ---" -ForegroundColor Yellow
            $dsgModulePath = Join-Path $script:V3Root "lib/modules/design-system-gate.ps1"
            if (Test-Path $dsgModulePath) {
                if (-not (Get-Command Invoke-DesignSystemGate -ErrorAction SilentlyContinue)) {
                    . $dsgModulePath
                }
                try {
                    $dsgResult = Invoke-DesignSystemGate -RepoRoot $RepoRoot -GsdDir $GsdDir -Config $Config

                    if ($dsgResult -and $dsgResult.Violations) {
                        $blockingCount = @($dsgResult.Violations | Where-Object { $_.Severity -eq "blocking" }).Count
                        $warningCount = @($dsgResult.Violations | Where-Object { $_.Severity -ne "blocking" }).Count
                        Write-Host "    Design System Gate: $blockingCount blocking, $warningCount warnings" -ForegroundColor $(
                            if ($blockingCount -gt 0) { "Red" } elseif ($warningCount -gt 0) { "Yellow" } else { "Green" }
                        )

                        # If block_on_violations is true and there are blocking violations, demote affected reqs
                        if ($dsgConfig.block_on_violations -and $blockingCount -gt 0) {
                            $matrixPath = Join-Path $GsdDir "requirements/requirements-matrix.json"
                            $matrix = Get-Content $matrixPath -Raw | ConvertFrom-Json
                            $demotedCount = 0
                            foreach ($violation in ($dsgResult.Violations | Where-Object { $_.Severity -eq "blocking" })) {
                                $affectedReq = $matrix.requirements | Where-Object {
                                    ($_.id -eq $violation.ReqId) -or ($_.req_id -eq $violation.ReqId)
                                }
                                if ($affectedReq -and $affectedReq.status -ne "partial") {
                                    $affectedReq.status = "partial"
                                    $affectedReq | Add-Member -NotePropertyName "design_gate_violation" -NotePropertyValue $violation.Rule -Force
                                    $demotedCount++
                                }
                            }
                            if ($demotedCount -gt 0) {
                                $matrix | ConvertTo-Json -Depth 10 | Set-Content $matrixPath -Encoding UTF8
                                Write-Host "    [DEMOTE] $demotedCount reqs demoted to 'partial' due to design system violations" -ForegroundColor Red
                            }
                        }
                    }
                    else {
                        Write-Host "    Design System Gate: PASSED (no violations)" -ForegroundColor Green
                    }
                } catch {
                    Write-Host "    [WARN] Design System Gate error: $($_.Exception.Message)" -ForegroundColor DarkYellow
                }
            }
            else {
                Write-Host "    [SKIP] design-system-gate.ps1 not found at $dsgModulePath" -ForegroundColor DarkGray
            }
        }

        # -- Phase 5c: Figma Completeness Check (after design system gate, before review) --
        $figmaCheckerPath = Join-Path $script:V3Root "lib/modules/figma-completeness-checker.ps1"
        if (Test-Path $figmaCheckerPath) {
            if (-not (Get-Command Invoke-FigmaCompletenessCheck -ErrorAction SilentlyContinue)) {
                . $figmaCheckerPath
            }
            try {
                Write-Host "`n  --- Figma Completeness Check ---" -ForegroundColor Yellow
                $figmaCheck = Invoke-FigmaCompletenessCheck -RepoRoot $RepoRoot -GsdDir $GsdDir -Config $Config

                if (-not $figmaCheck.Skipped -and $figmaCheck.NotSatisfied -gt 0) {
                    Write-Host "    Figma completeness: $($figmaCheck.Completeness)% ($($figmaCheck.Satisfied)/$($figmaCheck.Checked) satisfied)" -ForegroundColor $(
                        if ($figmaCheck.Completeness -ge 90) { "Yellow" } else { "Red" }
                    )

                    # Demote unsatisfied Figma reqs to not_started so they get picked up in next iteration
                    $matrixPath = Join-Path $GsdDir "requirements/requirements-matrix.json"
                    $matrix = Get-Content $matrixPath -Raw | ConvertFrom-Json
                    $demotedCount = 0
                    foreach ($unsatItem in ($figmaCheck.Report.unsatisfied | Where-Object { $_.partial })) {
                        $affectedReq = $matrix.requirements | Where-Object {
                            ($_.id -eq $unsatItem.req_id) -or ($_.req_id -eq $unsatItem.req_id)
                        }
                        if ($affectedReq -and $affectedReq.status -eq "satisfied") {
                            $affectedReq.status = "partial"
                            $affectedReq | Add-Member -NotePropertyName "figma_violation" -NotePropertyValue $unsatItem.reason -Force
                            $demotedCount++
                        }
                    }
                    if ($demotedCount -gt 0) {
                        $matrix.summary.satisfied = @($matrix.requirements | Where-Object { $_.status -eq "satisfied" }).Count
                        $matrix.summary.partial = @($matrix.requirements | Where-Object { $_.status -eq "partial" }).Count
                        $matrix.summary.not_started = @($matrix.requirements | Where-Object { $_.status -eq "not_started" }).Count
                        $matrix | ConvertTo-Json -Depth 10 | Set-Content $matrixPath -Encoding UTF8
                        Write-Host "    [FIGMA-DEMOTE] $demotedCount reqs demoted due to Figma completeness violations" -ForegroundColor Red
                    }
                }
                elseif (-not $figmaCheck.Skipped) {
                    Write-Host "    Figma completeness: 100% ($($figmaCheck.Satisfied)/$($figmaCheck.Checked))" -ForegroundColor Green
                }
            } catch {
                Write-Host "    [WARN] Figma completeness check error: $($_.Exception.Message)" -ForegroundColor DarkYellow
            }
        }

        # -- Review Phase (only for failed items after fix attempts) --
        if ("review" -in $phasesActive -and "review" -notin $phasesSkipped) {
            if ($validateResults.FailItems.Count -gt 0) {
                Write-Host "`n  --- Review ---" -ForegroundColor Yellow
                $reviewResults = Invoke-ReviewPhase -GsdDir $GsdDir -RepoRoot $RepoRoot `
                    -CacheBlocks $cacheBlocks -FailedItems $validateResults.FailItems `
                    -Iteration $iter -Config $Config
            }
            else {
                Write-Host "`n  --- Review: SKIPPED (all items passed local validation) ---" -ForegroundColor DarkGreen
            }
        }

        # -- Verify Phase --
        Write-Host "`n  --- Verify ---" -ForegroundColor Yellow
        $verifyResult = Invoke-VerifyPhase -GsdDir $GsdDir -RepoRoot $RepoRoot `
            -CacheBlocks $cacheBlocks -Iteration $iter -Config $Config `
            -Mode $Mode -BaselineSnapshot $baselineSnapshot `
            -ExecuteResults $executeResults -ValidateResults $validateResults `
            -ReviewResults $reviewResults

        $currentHealth = $verifyResult.HealthScore
        $healthDelta = $currentHealth - $prevHealth

        Save-HealthHistory -GsdDir $GsdDir -Iteration $iter -Score $currentHealth -Delta $healthDelta
        Write-Host "  Health: $currentHealth% (delta: $([math]::Round($healthDelta, 1)))" -ForegroundColor $(
            if ($healthDelta -gt 0) { "Green" } elseif ($healthDelta -eq 0) { "Yellow" } else { "Red" }
        )

        # Traceability matrix regeneration (zero LLM cost -- pure file scan)
        try {
            $traceResult = Invoke-TraceabilityUpdate -RepoRoot $RepoRoot -GsdDir $GsdDir -Config $Config
            if ($traceResult.Success) {
                Write-Host "  Traceability: $($traceResult.Mapped)/$($traceResult.Total) mapped ($($traceResult.ElapsedSec)s)" -ForegroundColor DarkGray
            }
        } catch {
            Write-Host "  [WARN] Traceability update failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }

        # Cost summary
        Save-CostSummary -GsdDir $GsdDir
        Write-Host "  $(Get-CostSummaryText)" -ForegroundColor DarkGray

        # Convergence check
        if ($currentHealth -ge $Config.target_health) {
            Write-Host "`n  CONVERGED! Health $currentHealth% >= target $($Config.target_health)%" -ForegroundColor Green
            $converged = $true
            break
        }

        # Stall check + Anti-Plateau integration
        if ($healthDelta -le 0) { $consecutiveZeroDelta++ } else { $consecutiveZeroDelta = 0 }

        $stall = Test-StallDetected -GsdDir $GsdDir -StallThreshold $Config.stall_threshold
        if ($stall.Stalled) {
            Write-Host "  [STALL] $($stall.Reason) (consecutive zero-delta: $consecutiveZeroDelta)" -ForegroundColor Red
            Send-GsdNotification -Title "GSD Stalled" -Message $stall.Reason -Tags "warning"

            # Anti-plateau: get stall-breaking action from supervisor (if available)
            $stallAction = $null
            try {
                $stallAction = Get-StallBreakingAction -GsdDir $GsdDir -ConsecutiveZero $consecutiveZeroDelta
            } catch {
                Write-Host "  [STALL] Get-StallBreakingAction not available, using defaults" -ForegroundColor DarkGray
            }

            if ($stallAction) {
                Write-Host "  [ANTI-PLATEAU] Action: $($stallAction.Action)" -ForegroundColor Cyan

                switch ($stallAction.Action) {
                    "escalate" {
                        # Flag stuck reqs for Opus/larger model in next execute
                        $matrixPath = Join-Path $GsdDir "requirements/requirements-matrix.json"
                        try {
                            $stallMatrix = Get-Content $matrixPath -Raw | ConvertFrom-Json
                            $stuckReqs = @($stallMatrix.requirements | Where-Object { $_.status -in @("not_started", "partial") } | Select-Object -First 5)
                            foreach ($sr in $stuckReqs) {
                                $sr | Add-Member -NotePropertyName "use_large_model" -NotePropertyValue $true -Force
                                $sr | Add-Member -NotePropertyName "notes" -NotePropertyValue "Escalated by anti-plateau (stall $consecutiveZeroDelta iterations)" -Force
                            }
                            $stallMatrix | ConvertTo-Json -Depth 10 | Set-Content $matrixPath -Encoding UTF8
                            Write-Host "  [ANTI-PLATEAU] Escalated $($stuckReqs.Count) stuck reqs to larger model" -ForegroundColor Yellow
                        } catch {
                            Write-Host "  [ANTI-PLATEAU] Escalate failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
                        }
                    }
                    "skip" {
                        # Mark stuck reqs as deferred, remove from scope
                        $matrixPath = Join-Path $GsdDir "requirements/requirements-matrix.json"
                        try {
                            $stallMatrix = Get-Content $matrixPath -Raw | ConvertFrom-Json
                            $stuckReqs = @($stallMatrix.requirements | Where-Object { $_.status -eq "not_started" } | Select-Object -First 3)
                            foreach ($sr in $stuckReqs) {
                                $sr.status = "deferred"
                                $sr | Add-Member -NotePropertyName "notes" -NotePropertyValue "Deferred by anti-plateau (stall $consecutiveZeroDelta iterations)" -Force
                            }
                            $stallMatrix | ConvertTo-Json -Depth 10 | Set-Content $matrixPath -Encoding UTF8
                            Write-Host "  [ANTI-PLATEAU] Deferred $($stuckReqs.Count) stuck reqs" -ForegroundColor Yellow
                        } catch {
                            Write-Host "  [ANTI-PLATEAU] Skip/defer failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
                        }
                    }
                }
            }

            # Force break after 5 consecutive zero-delta iterations
            if ($consecutiveZeroDelta -ge 5) {
                Write-Host "  [ANTI-PLATEAU] Force break: $consecutiveZeroDelta consecutive zero-delta iterations" -ForegroundColor Red
                Send-GsdNotification -Title "GSD Force Break" -Message "Pipeline halted after $consecutiveZeroDelta zero-progress iterations" -Tags "warning" -Priority "high"
                break
            }

            # Try spec-fix if available
            if ("spec-fix" -in $phasesActive) {
                Write-Host "`n  --- Spec Fix (stall recovery) ---" -ForegroundColor Yellow
                Invoke-SpecFixPhase -GsdDir $GsdDir -RepoRoot $RepoRoot `
                    -CacheBlocks $cacheBlocks -Config $Config
            }
        }

        # Regression check (feature_update mode)
        if ($Mode -eq "feature_update" -and $baselineSnapshot.Count -gt 0) {
            $regression = Test-RegressionDetected -GsdDir $GsdDir -BaselineSnapshot $baselineSnapshot
            if ($regression.Regressed) {
                Write-Host "  [HALT] Regression detected. Halting for human review." -ForegroundColor Red
                Send-GsdNotification -Title "GSD Regression Detected" `
                    -Message "$($regression.Items.Count) requirements regressed" -Tags "warning" -Priority "high"
                break
            }
        }

        # Git commit iteration (robust: diff check, retries, health+cost in message)
        Invoke-IterationCommit -RepoRoot $RepoRoot -Iteration $iter `
            -HealthPct $currentHealth -TotalCostUsd $script:CostState.TotalUsd

        $prevHealth = $currentHealth

        # ============================================================
        # PER-ITERATION LOG — write to central store
        # ============================================================
        $iterEndTime = Get-Date
        $iterLogData.completed_at = $iterEndTime.ToString("o")
        $iterLogData.duration_seconds = [math]::Round(($iterEndTime - $iterStartTime).TotalSeconds, 1)
        $iterLogData.health_pct = $currentHealth
        $iterLogData.health_delta = $healthDelta
        $iterLogData.cost_usd = [math]::Round($script:CostState.TotalUsd, 4)
        $iterLogData.batch_size = $batchReqs.Count
        $iterLogData.decomp_added = $script:DecompBudget.AddedThisIteration
        $iterLogData.consecutive_zero_delta = $consecutiveZeroDelta

        if ($iterLogDir) {
            $iterLogFile = Join-Path $iterLogDir "iter-$($globalIter.ToString('D4')).json"
            try {
                $iterLogData | ConvertTo-Json -Depth 5 | Set-Content $iterLogFile -Encoding UTF8
            } catch {
                Write-Host "  [WARN] Failed to write iteration log: $($_.Exception.Message)" -ForegroundColor DarkYellow
            }
        }

        # Update persistent iteration counter (so next run starts from correct number)
        if ($iterCounterFile) {
            try {
                @{
                    next_iteration    = $globalIter + 1
                    last_completed    = $globalIter
                    last_health       = $currentHealth
                    last_cost         = [math]::Round($script:CostState.TotalUsd, 4)
                    last_run_id       = $env:GSD_RUN_ID
                    repo              = $repoName
                    updated_at        = (Get-Date -Format "o")
                } | ConvertTo-Json | Set-Content $iterCounterFile -Encoding UTF8
            } catch {
                Write-Host "  [WARN] Failed to update iteration counter: $($_.Exception.Message)" -ForegroundColor DarkYellow
            }
        }

        # Memory cleanup between iterations -- prevent OOM/CPU spike from GC thrashing
        # Also clean up any stale background jobs that weren't removed
        Get-Job -State Completed -EA SilentlyContinue | Remove-Job -Force -EA SilentlyContinue
        Get-Job -State Failed -EA SilentlyContinue | Remove-Job -Force -EA SilentlyContinue
        $scopedReqs = $null; $batchReqs = $null
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()

        # Notification
        Send-GsdNotification -Title "GSD Iteration $iter (Global #$globalIter) Complete" `
            -Message "Health: $currentHealth% | Delta: $healthDelta | Budget: `$$([math]::Round($script:CostState.TotalUsd, 2))" `
            -Tags "chart_with_upwards_trend"

        Save-Checkpoint -GsdDir $GsdDir -Iteration $iter -Phase "iteration-complete" `
            -Health $currentHealth -BatchSize $batchSizeMax -Mode $Mode

        } catch {
            Write-Host "`n  [CRASH] Iteration $iter crashed: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "  Stack: $($_.ScriptStackTrace)" -ForegroundColor DarkRed
            Send-GsdNotification -Title "GSD Iteration $iter CRASHED" `
                -Message "Error: $($_.Exception.Message)" -Tags "warning" -Priority "high"
            try { Save-Checkpoint -GsdDir $GsdDir -Iteration $iter -Phase "crashed" -Health $currentHealth -BatchSize $batchSizeMax -Mode $Mode } catch {}
            continue
        }
    }

    # -- Cleanup --
    Stop-BackgroundMonitors
    Remove-GsdLock -GsdDir $GsdDir
    Save-CostSummary -GsdDir $GsdDir

    # Final traceability matrix (captures all iterations)
    try {
        Write-Host "`n  --- Final Traceability ---" -ForegroundColor Cyan
        $finalTrace = Invoke-TraceabilityUpdate -RepoRoot $RepoRoot -GsdDir $GsdDir -Config $Config
        if ($finalTrace.Success) {
            Write-Host "  Final traceability: $($finalTrace.Mapped)/$($finalTrace.Total) reqs mapped to files" -ForegroundColor Green
        }
    } catch {
        Write-Host "  [WARN] Final traceability update failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }

    if ($converged) {
        Clear-Checkpoint -GsdDir $GsdDir

        # -- Post-Convergence Integration Smoke Test --
        Write-Host "`n  --- Post-Convergence Integration Smoke Test ---" -ForegroundColor Cyan
        try {
            $smokeTestModule = Join-Path $PSScriptRoot "integration-smoke-test.ps1"
            if (Test-Path $smokeTestModule) {
                if (-not (Get-Command 'Invoke-IntegrationSmokeTest' -ErrorAction SilentlyContinue)) {
                    . $smokeTestModule
                }
                $smokeResult = Invoke-IntegrationSmokeTest -RepoRoot $RepoRoot
                $smokeColor = if ($smokeResult.Failed -eq 0) { "Green" } else { "Yellow" }
                Write-Host "  Integration smoke: $($smokeResult.Passed) pass, $($smokeResult.Failed) fail, $($smokeResult.Warnings) warn" -ForegroundColor $smokeColor

                # Write smoke test report to .gsd directory
                $smokeReportPath = Join-Path $GsdDir "integration-smoke-report.json"
                $smokeResult | ConvertTo-Json -Depth 5 | Set-Content $smokeReportPath -Encoding UTF8
                Write-Host "  Report saved: $smokeReportPath" -ForegroundColor DarkGray

                # Include smoke test results in notification
                $smokeMsg = if ($smokeResult.Failed -gt 0) {
                    $failDetails = ($smokeResult.Details | Where-Object { $_.Status -eq 'fail' } | ForEach-Object { $_.CheckName }) -join ', '
                    " | Smoke: $($smokeResult.Failed) FAIL ($failDetails)"
                } else { " | Smoke: ALL PASS" }
            } else {
                Write-Host "  [SKIP] integration-smoke-test.ps1 not found" -ForegroundColor DarkYellow
                $smokeMsg = ""
            }
        } catch {
            Write-Host "  [WARN] Integration smoke test failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
            $smokeMsg = " | Smoke: ERROR"
        }

        Send-GsdNotification -Title "GSD CONVERGED!" `
            -Message "Health: 100% | Cost: `$$([math]::Round($script:CostState.TotalUsd, 2)) | Mode: $Mode$smokeMsg" `
            -Tags "white_check_mark" -Priority "high"
    }

    $elapsed = [math]::Round(((Get-Date) - $pipelineStart).TotalMinutes, 1)
    Write-Host "`n============================================" -ForegroundColor $(if ($converged) { "Green" } else { "Yellow" })
    Write-Host "  Pipeline $Mode $(if ($converged) { 'CONVERGED' } else { 'STOPPED' })" -ForegroundColor $(if ($converged) { "Green" } else { "Yellow" })
    Write-Host "  Duration: ${elapsed}m | Cost: `$$([math]::Round($script:CostState.TotalUsd, 2))" -ForegroundColor DarkGray
    Write-Host "============================================" -ForegroundColor $(if ($converged) { "Green" } else { "Yellow" })

    return @{
        Success     = $converged
        Mode        = $Mode
        Iterations  = $iter
        HealthScore = $currentHealth
        TotalCost   = $script:CostState.TotalUsd
        Duration    = $elapsed
    }
}

# ============================================================
# SPEC-ALIGNMENT PHASE
# ============================================================

function Invoke-SpecAlignmentPhase {
    <#
    .SYNOPSIS
        Compares spec documents vs requirements matrix vs codebase to detect drift.
        Runs after spec-gate, before iterations. Blocks pipeline if drift > 20%.
    #>
    param(
        [string]$GsdDir,
        [string]$RepoRoot,
        [array]$CacheBlocks,
        [PSObject]$Config,
        [PSObject]$Inventory
    )

    Write-Host "`n--- Spec Alignment ---" -ForegroundColor Yellow

    # Gather spec docs from docs/ and design/ directories
    $specDocs = @()
    foreach ($dir in @("docs", "design")) {
        $dirPath = Join-Path $RepoRoot $dir
        if (Test-Path $dirPath) {
            $files = Get-ChildItem -Path $dirPath -Recurse -File -Include "*.md","*.txt","*.json" -ErrorAction SilentlyContinue |
                Select-Object -First 15
            foreach ($f in $files) {
                $relPath = $f.FullName.Replace($RepoRoot, "").TrimStart("\", "/")
                $content = Get-Content $f.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                if ($content -and $content.Length -lt 8000) {
                    $specDocs += "### $relPath`n$content"
                }
            }
        }
    }
    $specText = if ($specDocs.Count -gt 0) { $specDocs -join "`n`n---`n`n" } else { "(no spec docs found in docs/ or design/)" }
    if ($specText.Length -gt 30000) { $specText = $specText.Substring(0, 30000) + "`n... (truncated)" }

    # Read requirements matrix summary
    $matrixPath = Join-Path $GsdDir "requirements/requirements-matrix.json"
    $matrixSummary = "(no matrix)"
    if (Test-Path $matrixPath) {
        try {
            $matrixObj = Get-Content $matrixPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $mReqs = if ($matrixObj.requirements) { $matrixObj.requirements } else { @() }
            $reqList = ($mReqs | Select-Object -First 80 | ForEach-Object {
                $rid = if ($_.id) { $_.id } else { $_.req_id }
                "- $rid [$($_.status)]: $($_.description)"
            }) -join "`n"
            $matrixSummary = "Total: $($mReqs.Count)`n$reqList"
        } catch {}
    }

    # File inventory summary
    $fileList = if ($Inventory.source_files) {
        ($Inventory.source_files | Select-Object -First 100) -join "`n"
    } else { "(no inventory)" }

    $prompt = @"
You are a spec-alignment auditor. Compare these spec documents against the requirements matrix and file inventory.

## Spec Documents
$specText

## Requirements Matrix
$matrixSummary

## File Inventory (first 100 source files)
$fileList

## Task
Produce a JSON report:
{
  "drift_pct": <number 0-100>,
  "missing_in_code": ["<req_ids or descriptions of spec items not covered by requirements or code>"],
  "orphaned_code": ["<files that exist in codebase but have no matching spec or requirement>"],
  "status": "pass" | "warn" | "block",
  "summary": "<one-line summary>"
}

Rules:
- drift_pct > 20 → status "block"
- drift_pct 5-20 → status "warn"
- drift_pct < 5 → status "pass"
- missing_in_code: spec items with no requirement AND no code implementing them
- orphaned_code: significant source files with no matching spec (ignore configs, tests, utilities)
"@

    $result = Invoke-SonnetApi -CacheBlocks $CacheBlocks -UserMessage $prompt `
        -MaxTokens 4096 -UseCache -JsonMode -Phase "spec-align"

    if ($result.Usage) { Add-ApiCallCost -Model $script:SonnetModel -Usage $result.Usage -Phase "spec-align" }

    $report = $result.Parsed
    $blocked = $false

    if ($report) {
        # Save report
        $specsDir = Join-Path $GsdDir "specs"
        if (-not (Test-Path $specsDir)) { New-Item -ItemType Directory -Path $specsDir -Force | Out-Null }
        $result.Text | Set-Content (Join-Path $specsDir "spec-alignment-report.json") -Encoding UTF8

        $driftPct = if ($report.drift_pct) { $report.drift_pct } else { 0 }
        $status = if ($report.status) { $report.status } else { "pass" }

        Write-Host "  Drift: $driftPct% | Status: $status" -ForegroundColor $(
            if ($status -eq "block") { "Red" } elseif ($status -eq "warn") { "Yellow" } else { "Green" }
        )
        if ($report.summary) { Write-Host "  $($report.summary)" -ForegroundColor DarkGray }
        if ($report.missing_in_code -and $report.missing_in_code.Count -gt 0) {
            Write-Host "  Missing in code: $($report.missing_in_code.Count) items" -ForegroundColor DarkYellow
        }
        if ($report.orphaned_code -and $report.orphaned_code.Count -gt 0) {
            Write-Host "  Orphaned code: $($report.orphaned_code.Count) files" -ForegroundColor DarkYellow
        }

        if ($status -eq "block" -or $driftPct -gt 20) {
            Write-Host "  [BLOCKED] Drift $driftPct% exceeds 20% threshold. Fix spec alignment first." -ForegroundColor Red
            $blocked = $true
        }
    } else {
        Write-Host "  [WARN] Spec alignment returned no parseable output" -ForegroundColor DarkYellow
    }

    return @{ Blocked = $blocked; Report = $report; Success = $result.Success }
}

# ============================================================
# INTELLIGENT BATCHING
# ============================================================

function Select-IntelligentBatch {
    <#
    .SYNOPSIS
        Selects a batch of requirements using interface clustering, priority sorting,
        and dependency chain awareness instead of simple Select-Object -First N.
    #>
    param(
        [array]$Requirements,
        [int]$BatchSize,
        [string]$GsdDir = ""
    )

    if ($Requirements.Count -le $BatchSize) { return $Requirements }

    # Load fail tracker to deprioritize repeatedly failing reqs
    $failTracker = @{}
    if ($GsdDir) {
        $failTrackerPath = Join-Path $GsdDir "requirements/fail-tracker.json"
        if (Test-Path $failTrackerPath) {
            try {
                $ftData = Get-Content $failTrackerPath -Raw | ConvertFrom-Json
                foreach ($prop in $ftData.PSObject.Properties) { $failTracker[$prop.Name] = [int]$prop.Value }
            } catch {}
        }
    }

    # Priority weight map (lower = higher priority)
    $priorityWeight = @{ "critical" = 0; "high" = 1; "medium" = 2; "low" = 3 }

    # Score each requirement: priority + fail penalty + dependency bonus
    $scored = foreach ($req in $Requirements) {
        $rid = if ($req.id) { $req.id } else { $req.req_id }
        $prio = if ($req.priority) { $req.priority.ToLower() } else { "medium" }
        $pw = if ($priorityWeight.ContainsKey($prio)) { $priorityWeight[$prio] } else { 2 }
        $failPenalty = if ($failTracker.ContainsKey($rid)) { $failTracker[$rid] * 2 } else { 0 }
        $iface = if ($req.interface) { $req.interface } else { "unknown" }

        [PSCustomObject]@{
            Req       = $req
            ReqId     = $rid
            Interface = $iface
            Score     = $pw + $failPenalty
            HasParent = [bool]$req.parent_id
        }
    }

    # Sort by score (ascending = best first), then group by interface
    $sorted = $scored | Sort-Object Score

    # Fill batch preferring same-interface clusters
    $selected = [System.Collections.ArrayList]::new()
    $byInterface = $sorted | Group-Object Interface

    # Round-robin across interfaces, sorted by best score in group
    $ifaceQueues = @{}
    foreach ($group in ($byInterface | Sort-Object { ($_.Group | Measure-Object Score -Minimum).Minimum })) {
        $ifaceQueues[$group.Name] = [System.Collections.Queue]::new()
        foreach ($item in $group.Group) {
            $ifaceQueues[$group.Name].Enqueue($item)
        }
    }

    # Fill with clusters: take up to 3 from same interface before moving to next
    $clusterSize = [math]::Max(2, [math]::Floor($BatchSize / [math]::Max(1, $ifaceQueues.Count)))
    while ($selected.Count -lt $BatchSize) {
        $addedThisRound = $false
        foreach ($ifaceName in @($ifaceQueues.Keys)) {
            $queue = $ifaceQueues[$ifaceName]
            $taken = 0
            while ($queue.Count -gt 0 -and $taken -lt $clusterSize -and $selected.Count -lt $BatchSize) {
                $item = $queue.Dequeue()
                # Respect dependency chains: if parent_id is in batch, include child
                $selected.Add($item.Req) | Out-Null
                $taken++
                $addedThisRound = $true
            }
            if ($queue.Count -eq 0) { $ifaceQueues.Remove($ifaceName) }
        }
        if (-not $addedThisRound) { break }
    }

    Write-Host "  [BATCH] Intelligent: $($selected.Count) reqs from $($byInterface.Count) interfaces" -ForegroundColor DarkGray
    return @($selected)
}

# ============================================================
# COMMIT ENFORCEMENT
# ============================================================

function Invoke-IterationCommit {
    <#
    .SYNOPSIS
        Robust git commit with diff check, health/cost in message, timeout, and retries.
    #>
    param(
        [string]$RepoRoot,
        [int]$Iteration,
        [double]$HealthPct,
        [double]$TotalCostUsd,
        [int]$TimeoutSec = 60,
        [int]$MaxRetries = 3
    )

    # Check for real changes before committing
    try {
        $diffOutput = git -C $RepoRoot diff --stat HEAD 2>&1 | Out-String
        $untrackedCount = @(git -C $RepoRoot ls-files --others --exclude-standard 2>&1).Count
    } catch {
        $diffOutput = ""
        $untrackedCount = 0
    }

    if ([string]::IsNullOrWhiteSpace($diffOutput) -and $untrackedCount -eq 0) {
        Write-Host "  [GIT] No changes to commit" -ForegroundColor DarkGray
        return
    }

    $costStr = [math]::Round($TotalCostUsd, 2)
    $commitMsg = "GSD v3: Iteration $Iteration - health $HealthPct% | cost `$$costStr"

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            $gitJob = Start-Job -ScriptBlock {
                param($root, $msg)
                git -C $root add -A 2>&1 | Out-Null
                $result = git -C $root commit -m $msg 2>&1 | Out-String
                return $result
            } -ArgumentList $RepoRoot, $commitMsg

            $gitDone = $gitJob | Wait-Job -Timeout $TimeoutSec
            if (-not $gitDone) {
                Write-Host "  [GIT] Commit timed out after ${TimeoutSec}s (attempt $attempt/$MaxRetries)" -ForegroundColor Yellow
                $gitJob | Stop-Job -PassThru | Remove-Job -Force
                if ($attempt -lt $MaxRetries) { Start-Sleep -Seconds 2; continue }
            } else {
                $output = Receive-Job -Job $gitJob
                $gitJob | Remove-Job -Force
                Write-Host "  [GIT] Committed: $commitMsg" -ForegroundColor DarkGray
                return
            }
        } catch {
            Write-Host "  [GIT] Commit failed (attempt $attempt/$MaxRetries): $($_.Exception.Message)" -ForegroundColor Yellow
            if ($attempt -lt $MaxRetries) { Start-Sleep -Seconds 2 }
        }
    }
    Write-Host "  [GIT] All $MaxRetries commit attempts failed -- continuing pipeline" -ForegroundColor DarkYellow
}

# ============================================================
# MULTI-PIPELINE SUPPORT
# ============================================================

function Start-MultiPipeline {
    <#
    .SYNOPSIS
        Launches parallel pipelines per interface (database first, then backend, then frontends).
        Only activates when config.multi_pipeline.enabled = true.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$Mode = "greenfield",
        [PSObject]$Config,
        [PSObject]$AgentMap,
        [string]$NtfyTopic = "auto"
    )

    $multiConfig = $Config.multi_pipeline
    if (-not $multiConfig -or $multiConfig.enabled -ne $true) {
        Write-Host "  [MULTI-PIPELINE] Not enabled in config. Running single pipeline." -ForegroundColor DarkGray
        return Start-V3Pipeline -RepoRoot $RepoRoot -Mode $Mode -Config $Config -AgentMap $AgentMap -NtfyTopic $NtfyTopic
    }

    $maxParallel = if ($multiConfig.max_parallel) { $multiConfig.max_parallel } else { 3 }
    Write-Host "`n============================================" -ForegroundColor Magenta
    Write-Host "  GSD V3 Multi-Pipeline ($Mode)" -ForegroundColor Magenta
    Write-Host "  Max parallel: $maxParallel" -ForegroundColor DarkGray
    Write-Host "============================================" -ForegroundColor Magenta

    # Discover interfaces from inventory
    $GsdDir = Join-Path $RepoRoot ".gsd"
    $inventory = Build-FileInventory -RepoRoot $RepoRoot -GsdDir $GsdDir
    $interfaces = @($inventory.by_interface.Keys)
    Write-Host "  Discovered interfaces: $($interfaces -join ', ')" -ForegroundColor DarkGray

    # Categorize interfaces
    $dbInterfaces = @($interfaces | Where-Object { $_ -match "database|sql|db" })
    $backendInterfaces = @($interfaces | Where-Object { $_ -match "backend|server|api" })
    $frontendInterfaces = @($interfaces | Where-Object { $_ -notin ($dbInterfaces + $backendInterfaces) })

    $allResults = @()

    # Phase 1: Database pipeline (sequential, must complete first)
    foreach ($iface in $dbInterfaces) {
        Write-Host "`n  --- Database Pipeline: $iface ---" -ForegroundColor Yellow
        $result = Start-V3Pipeline -RepoRoot $RepoRoot -Mode $Mode -Config $Config `
            -AgentMap $AgentMap -Scope "interface:$iface" -NtfyTopic $NtfyTopic
        $allResults += $result
    }

    # Phase 2: Backend pipeline (sequential)
    foreach ($iface in $backendInterfaces) {
        Write-Host "`n  --- Backend Pipeline: $iface ---" -ForegroundColor Yellow
        $result = Start-V3Pipeline -RepoRoot $RepoRoot -Mode $Mode -Config $Config `
            -AgentMap $AgentMap -Scope "interface:$iface" -NtfyTopic $NtfyTopic
        $allResults += $result
    }

    # Phase 3: Frontend pipelines (parallel via Start-Job)
    if ($frontendInterfaces.Count -gt 0) {
        Write-Host "`n  --- Frontend Pipelines (parallel) ---" -ForegroundColor Yellow
        $jobs = @()
        foreach ($iface in ($frontendInterfaces | Select-Object -First $maxParallel)) {
            Write-Host "    Launching: $iface" -ForegroundColor DarkCyan
            $scriptPath = $PSCommandPath  # This module's path
            $job = Start-Job -ScriptBlock {
                param($sp, $root, $m, $cfg, $am, $scope, $topic)
                . $sp
                Start-V3Pipeline -RepoRoot $root -Mode $m -Config $cfg `
                    -AgentMap $am -Scope $scope -NtfyTopic $topic
            } -ArgumentList $scriptPath, $RepoRoot, $Mode, $Config, $AgentMap, "interface:$iface", $NtfyTopic
            $jobs += @{ Job = $job; Interface = $iface }
        }

        # Wait for all frontend jobs
        $timeout = 3600  # 1 hour max per frontend pipeline
        foreach ($j in $jobs) {
            $completed = $j.Job | Wait-Job -Timeout $timeout
            if ($completed) {
                $result = Receive-Job -Job $j.Job
                $allResults += $result
                Write-Host "    [DONE] $($j.Interface): Health $($result.HealthScore)%" -ForegroundColor $(if ($result.Success) { "Green" } else { "Yellow" })
            } else {
                Write-Host "    [TIMEOUT] $($j.Interface) timed out after ${timeout}s" -ForegroundColor Red
                $j.Job | Stop-Job -PassThru | Remove-Job -Force
            }
        }
        Get-Job -State Completed -EA SilentlyContinue | Remove-Job -Force -EA SilentlyContinue
    }

    # Aggregate health
    $avgHealth = if ($allResults.Count -gt 0) {
        [math]::Round(($allResults | ForEach-Object { $_.HealthScore } | Measure-Object -Average).Average, 1)
    } else { 0 }
    $totalCost = ($allResults | ForEach-Object { $_.TotalCost } | Measure-Object -Sum).Sum

    Write-Host "`n============================================" -ForegroundColor Magenta
    Write-Host "  Multi-Pipeline Complete" -ForegroundColor Magenta
    Write-Host "  Avg Health: $avgHealth% | Total Cost: `$$([math]::Round($totalCost, 2))" -ForegroundColor DarkGray
    Write-Host "============================================" -ForegroundColor Magenta

    return @{
        Success     = ($allResults | Where-Object { $_.Success }).Count -eq $allResults.Count
        Mode        = $Mode
        HealthScore = $avgHealth
        TotalCost   = $totalCost
        Pipelines   = $allResults.Count
    }
}

# ============================================================
# PHASE IMPLEMENTATIONS
# ============================================================

function Build-SpecContext {
    param([string]$RepoRoot, [string]$GsdDir, [PSObject]$Inventory)

    $context = "# Specification Documents`n`n"

    # Collect all spec/doc files from inventory
    $specFiles = @()
    if ($Inventory.spec_files) { $specFiles += $Inventory.spec_files }

    # Also check design folders
    foreach ($ifaceKey in @("web", "mcp-admin", "browser", "mobile", "agent")) {
        if ($Inventory.design_files[$ifaceKey]) {
            $analysisFiles = $Inventory.design_files[$ifaceKey] | Where-Object { $_ -like "*_analysis*" }
            $specFiles += $analysisFiles
        }
    }

    foreach ($file in ($specFiles | Select-Object -First 20)) {  # Cap at 20 files for token budget
        $fullPath = Join-Path $RepoRoot $file
        if (Test-Path $fullPath) {
            $content = Get-Content $fullPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($content -and $content.Length -lt 10000) {  # Skip huge files
                $context += "## $file`n`n$content`n`n---`n`n"
            }
        }
    }

    # Include requirements matrix SUMMARY (not full content -- matrix can be 200K+ tokens)
    $matrixPath = Join-Path $GsdDir "requirements/requirements-matrix.json"
    if (Test-Path $matrixPath) {
        try {
            $matrixObj = Get-Content $matrixPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $mReqs = if ($matrixObj.requirements) { $matrixObj.requirements } else { @() }
            $mTotal = $mReqs.Count
            $mSatisfied = @($mReqs | Where-Object { $_.status -eq "satisfied" }).Count
            $mPartial = @($mReqs | Where-Object { $_.status -eq "partial" }).Count
            $mNotStarted = @($mReqs | Where-Object { $_.status -eq "not_started" }).Count
            $mHealth = if ($mTotal -gt 0) { [math]::Round(($mSatisfied + $mPartial * 0.5) / $mTotal * 100, 1) } else { 0 }

            $context += "## Requirements Matrix Summary`n`n"
            $context += "Total: $mTotal | Satisfied: $mSatisfied | Partial: $mPartial | Not Started: $mNotStarted | Health: $mHealth%`n`n"

            # Only include non-satisfied requirements (the ones that need work)
            $activeReqs = @($mReqs | Where-Object { $_.status -in @("not_started", "partial") } | Select-Object -First 30)
            if ($activeReqs.Count -gt 0) {
                $context += "### Active Requirements (not_started + partial, first 30)`n`n"
                foreach ($r in $activeReqs) {
                    $rid = if ($r.req_id) { $r.req_id } else { $r.id }
                    $context += "- $rid [$($r.status)]: $($r.description)`n"
                }
                $context += "`n"
            }
        }
        catch {
            $context += "## Requirements Matrix`n`n(Failed to parse matrix: $($_.Exception.Message))`n`n"
        }
    }

    return $context
}

function Build-BlueprintContext {
    param([string]$RepoRoot, [string]$GsdDir, [PSObject]$Inventory)

    $context = "# Blueprint Manifest`n`n"
    $context += "## File Inventory Summary`n`n"
    $context += "Total files: $($Inventory.total_files)`n`n"

    # Directory summary
    $context += "### Directories`n`n"
    foreach ($dir in ($Inventory.by_directory.Keys | Sort-Object)) {
        $context += "- $dir/ ($($Inventory.by_directory[$dir]) files)`n"
    }

    # Interface summary
    $context += "`n### Detected Interfaces`n`n"
    foreach ($iface in ($Inventory.by_interface.Keys | Sort-Object)) {
        $context += "- $iface : $($Inventory.by_interface[$iface].Count) source files`n"
    }

    # Design files summary
    $context += "`n### Design Files`n`n"
    foreach ($iface in ($Inventory.design_files.Keys | Sort-Object)) {
        $context += "- $iface : $($Inventory.design_files[$iface].Count) design files`n"
    }

    # File tree (truncated)
    $treePath = Join-Path $GsdDir "file-map-tree.md"
    if (Test-Path $treePath) {
        $tree = Get-Content $treePath -Raw -Encoding UTF8
        if ($tree.Length -gt 3000) { $tree = $tree.Substring(0, 3000) + "`n... (truncated, $($tree.Length) chars total)" }
        $context += "`n## File Tree`n`n$tree"
    }

    return $context
}

function Invoke-SpecGatePhase {
    param(
        [string]$GsdDir, [string]$RepoRoot, [array]$CacheBlocks,
        [PSObject]$Config, [string]$Mode, [PSObject]$Inventory
    )

    $promptPath = Join-Path $script:V3Root "prompts/sonnet/01-spec-gate.md"
    $prompt = if (Test-Path $promptPath) { Get-Content $promptPath -Raw -Encoding UTF8 } else { "Analyze the spec documents in the cached context. Output JSON with overall_status, clarity_score, conflicts, ambiguities." }

    # For incremental mode, use different prompt
    if ($Mode -eq "feature_update") {
        $incrPath = Join-Path $script:V3Root "prompts/sonnet/01-spec-gate-incremental.md"
        if (Test-Path $incrPath) { $prompt = Get-Content $incrPath -Raw -Encoding UTF8 }
    }

    # Spec-gate needs enough tokens for large projects (MyTest had 228+ lines of JSON output)
    $specGateMaxTokens = 16000
    $result = Invoke-SonnetApi -CacheBlocks $CacheBlocks -UserMessage $prompt `
        -MaxTokens $specGateMaxTokens -UseCache -JsonMode -Phase "spec-gate"

    if ($result.Usage) { Add-ApiCallCost -Model $script:SonnetModel -Usage $result.Usage -Phase "spec-gate" }

    # Retry with larger token limit if truncated
    if (-not $result.Parsed -and ($result.StopReason -eq "max_tokens" -or ($result.Text -and $result.Text.Length -gt 3000))) {
        Write-Host "    [RETRY] Spec-gate truncated at $specGateMaxTokens tokens, retrying with 32000..." -ForegroundColor Yellow
        $specGateMaxTokens = 32000
        $result = Invoke-SonnetApi -CacheBlocks $CacheBlocks -UserMessage $prompt `
            -MaxTokens $specGateMaxTokens -UseCache -JsonMode -Phase "spec-gate-retry"
        if ($result.Usage) { Add-ApiCallCost -Model $script:SonnetModel -Usage $result.Usage -Phase "spec-gate-retry" }
    }

    $blocked = $false
    if ($result.Parsed) {
        $report = $result.Parsed
        $blocked = ($report.overall_status -eq "block")

        $reportPath = Join-Path $GsdDir "specs/spec-quality-report.json"
        $result.Text | Set-Content $reportPath -Encoding UTF8

        # If spec-gate returned requirements_derived, seed the requirements matrix
        if ($report.requirements_derived -and $report.requirements_derived.Count -gt 0) {
            $matrixPath = Join-Path $GsdDir "requirements/requirements-matrix.json"
            if (-not (Test-Path $matrixPath)) {
                Write-Host "    [SEED] Seeding requirements matrix with $($report.requirements_derived.Count) requirements from spec-gate" -ForegroundColor Cyan
                $matrix = @{
                    generated_at = (Get-Date -Format "o")
                    source = "spec-gate"
                    requirements = @($report.requirements_derived | ForEach-Object {
                        @{
                            id = $_.id
                            description = $_.description
                            source = if ($_.source) { $_.source } else { "spec" }
                            interface = if ($_.interface) { $_.interface } else { "backend" }
                            category = if ($_.category) { $_.category } else { "implementation" }
                            priority = if ($_.priority) { $_.priority } else { "medium" }
                            status = "not_started"
                            acceptance_criteria = if ($_.acceptance_criteria) { $_.acceptance_criteria } else { @() }
                        }
                    })
                }
                $matrix | ConvertTo-Json -Depth 5 | Set-Content $matrixPath -Encoding UTF8
                Write-Host "    [SEED] Requirements matrix created: $($matrix.requirements.Count) requirements" -ForegroundColor Green
            }
        }

        Write-Host "  Status: $($report.overall_status) | Clarity: $($report.clarity_score)" -ForegroundColor $(
            if ($report.overall_status -eq "block") { "Red" }
            elseif ($report.overall_status -eq "warn") { "Yellow" }
            else { "Green" }
        )
    } else {
        Write-Host "    [WARN] Spec-gate failed to parse. Pipeline will attempt to proceed with research phase." -ForegroundColor DarkYellow
    }

    return @{ Blocked = $blocked; Report = $result.Parsed; Success = $result.Success }
}

function Invoke-ResearchPhase {
    param(
        [string]$GsdDir, [string]$RepoRoot, [array]$CacheBlocks,
        [array]$Requirements, [int]$Iteration, [PSObject]$Config, [PSObject]$Inventory
    )

    $promptPath = Join-Path $script:V3Root "prompts/sonnet/02-research.md"
    $promptTemplate = if (Test-Path $promptPath) { Get-Content $promptPath -Raw -Encoding UTF8 } else {
        "Analyze the requirements below and discover patterns, dependencies, and tech decisions. Output JSON."
    }

    $reqSummary = ($Requirements | ForEach-Object { $rid = if ($_.req_id) { $_.req_id } else { $_.id }; "- ${rid}: $($_.description)" }) -join "`n"
    $prompt = $promptTemplate.Replace("{{ITERATION}}", "$Iteration")
    $prompt = $prompt.Replace("{{REQUIREMENTS}}", $reqSummary)

    # File inventory: use source_files (not all_files) and cap at 150 to control token budget
    $inventoryList = if ($Inventory.source_files) { $Inventory.source_files | Select-Object -First 150 } else { $Inventory.all_files | Select-Object -First 150 }
    $inventoryText = ($inventoryList -join "`n") + "`n`n(Total files: $($Inventory.total_files), showing first 150 source files)"
    $prompt = $prompt.Replace("{{FILE_INVENTORY}}", $inventoryText)

    # Scale research tokens with requirement count (1500 per req, min 6000, max 16000)
    $researchMaxTokens = [math]::Max(6000, [math]::Min(16000, $Requirements.Count * 1500))
    Write-Host "    [RESEARCH] MaxTokens: $researchMaxTokens for $($Requirements.Count) requirements" -ForegroundColor DarkGray

    $result = Invoke-SonnetApi -CacheBlocks $CacheBlocks -UserMessage $prompt `
        -MaxTokens $researchMaxTokens -UseCache -JsonMode -Phase "research"

    if ($result.Usage) { Add-ApiCallCost -Model $script:SonnetModel -Usage $result.Usage -Phase "research" }

    if ($result.Text) {
        $researchDir = Join-Path $GsdDir "research"
        Set-Content (Join-Path $researchDir "iteration-$Iteration.json") -Value $result.Text -Encoding UTF8
    }

    return $result.Parsed
}

function Invoke-PlanPhase {
    param(
        [string]$GsdDir, [string]$RepoRoot, [array]$CacheBlocks,
        [array]$Requirements, [int]$Iteration, [PSObject]$Research,
        [PSObject]$Config, [string]$Mode, [PSObject]$Inventory
    )

    $promptPath = Join-Path $script:V3Root "prompts/sonnet/03-plan.md"
    $promptTemplate = if (Test-Path $promptPath) { Get-Content $promptPath -Raw -Encoding UTF8 } else {
        "Create implementation plans for each requirement. Output JSON with plans array."
    }

    $reqSummary = ($Requirements | ForEach-Object { $rid = if ($_.req_id) { $_.req_id } else { $_.id }; "- ${rid}: $($_.description) [interface: $($_.interface)]" }) -join "`n"

    # Cap research output to prevent token bloat (can grow unbounded across iterations)
    $researchSummary = "(no research)"
    if ($Research) {
        $researchJson = ConvertTo-CleanJson -InputObject $Research -Depth 5 -Compress
        $researchMaxChars = 16000  # Allow plan to see most of the research (was 8000, caused incomplete plans)
        if ($researchJson.Length -gt $researchMaxChars) {
            $researchSummary = $researchJson.Substring(0, $researchMaxChars) + "... (truncated, $($researchJson.Length) chars)"
            Write-Host "    [PLAN] Research truncated: $($researchJson.Length) -> $researchMaxChars chars" -ForegroundColor DarkYellow
        } else {
            $researchSummary = $researchJson
        }
    }

    $prompt = $promptTemplate.Replace("{{ITERATION}}", "$Iteration")
    $prompt = $prompt.Replace("{{REQUIREMENTS}}", $reqSummary)
    $prompt = $prompt.Replace("{{RESEARCH}}", $researchSummary)
    $prompt = $prompt.Replace("{{FILE_INVENTORY}}", ($Inventory.source_files | Select-Object -First 100) -join "`n")

    # Plan output scales with batch size: ~2K tokens per requirement
    $planMaxTokens = [math]::Min(4096 + ($Requirements.Count * 4000), 65536)
    Write-Host "    [PLAN] MaxTokens: $planMaxTokens for $($Requirements.Count) requirements" -ForegroundColor DarkGray

    $result = Invoke-SonnetApi -CacheBlocks $CacheBlocks -UserMessage $prompt `
        -MaxTokens $planMaxTokens -UseCache -JsonMode -Phase "plan"

    if ($result.Usage) { Add-ApiCallCost -Model $script:SonnetModel -Usage $result.Usage -Phase "plan" }

    # If plan was truncated (max_tokens), retry with half the requirements
    if (-not $result.Success -and $result.StopReason -eq "max_tokens" -and $Requirements.Count -gt 3) {
        $halfCount = [math]::Floor($Requirements.Count / 2)
        Write-Host "    [PLAN] Truncated with $($Requirements.Count) reqs. Retrying with first $halfCount..." -ForegroundColor Yellow

        $halfReqs = $Requirements | Select-Object -First $halfCount
        $reqSummary2 = ($halfReqs | ForEach-Object { $rid = if ($_.req_id) { $_.req_id } else { $_.id }; "- ${rid}: $($_.description) [interface: $($_.interface)]" }) -join "`n"
        $prompt2 = $promptTemplate.Replace("{{ITERATION}}", "$Iteration")
        $prompt2 = $prompt2.Replace("{{REQUIREMENTS}}", $reqSummary2)
        $prompt2 = $prompt2.Replace("{{RESEARCH}}", $researchSummary)
        $prompt2 = $prompt2.Replace("{{FILE_INVENTORY}}", ($Inventory.source_files | Select-Object -First 100) -join "`n")

        $result = Invoke-SonnetApi -CacheBlocks $CacheBlocks -UserMessage $prompt2 `
            -MaxTokens $planMaxTokens -UseCache -JsonMode -Phase "plan-retry"
        if ($result.Usage) { Add-ApiCallCost -Model $script:SonnetModel -Usage $result.Usage -Phase "plan-retry" }
    }

    if ($result.Text) {
        $plansDir = Join-Path $GsdDir "plans"
        Set-Content (Join-Path $plansDir "iteration-$Iteration.json") -Value $result.Text -Encoding UTF8
    }

    return $result.Parsed
}

function Invoke-ExecutePhase {
    param(
        [string]$GsdDir, [string]$RepoRoot, [array]$Plans,
        [string]$Stage = "fill", [PSObject]$Config, [PSObject]$Inventory,
        [PSObject]$SkeletonResults = $null
    )

    # -- Existing Codebase Mode: skip satisfied requirements in execute --
    $ecmConfig = $Config.existing_codebase_mode
    if ($ecmConfig -and $ecmConfig.skip_satisfied_in_execute) {
        $skipPatterns = @($ecmConfig.skip_patterns_in_execute)
        if ($skipPatterns.Count -gt 0) {
            $matrixPathEcm = Join-Path $GsdDir "requirements/requirements-matrix.json"
            $satisfiedIds = @{}
            if (Test-Path $matrixPathEcm) {
                try {
                    $matrixEcm = Get-Content $matrixPathEcm -Raw | ConvertFrom-Json
                    foreach ($req in $matrixEcm.requirements) {
                        $rid = if ($req.id) { $req.id } else { $req.req_id }
                        if ($req.status -and ($req.status -in $skipPatterns)) {
                            $satisfiedIds[$rid] = $true
                        }
                    }
                } catch {}
            }
            if ($satisfiedIds.Count -gt 0) {
                $beforeCount = $Plans.Count
                $Plans = @($Plans | Where-Object { -not $satisfiedIds.ContainsKey($_.req_id) })
                $skippedCount = $beforeCount - $Plans.Count
                if ($skippedCount -gt 0) {
                    Write-Host "    [ECM] Skipped $skippedCount satisfied requirements from execute batch" -ForegroundColor Cyan
                }
            }
        }
        if ($Plans.Count -eq 0) {
            Write-Host "    [ECM] All requirements in batch already satisfied. Nothing to execute." -ForegroundColor Green
            return @{ Results = @{}; Completed = 0; Failed = 0 }
        }
    }

    $promptPath = if ($Stage -eq "skeleton") {
        Join-Path $script:V3Root "prompts/codex-mini/04a-execute-skeleton.md"
    } else {
        Join-Path $script:V3Root "prompts/codex-mini/04b-execute-fill.md"
    }

    $promptTemplate = if (Test-Path $promptPath) { Get-Content $promptPath -Raw -Encoding UTF8 } else {
        "Generate production-ready code. Follow the plan exactly. No stubs or placeholders."
    }

    # Load interface conventions
    $conventionsPath = Join-Path $script:V3Root "prompts/shared/coding-conventions.md"
    $conventions = if (Test-Path $conventionsPath) { Get-Content $conventionsPath -Raw -Encoding UTF8 } else { "" }

    # Pre-filter: Remove existing real-implementation files from plans to avoid FILL stub waste
    if ($Stage -eq "skeleton" -or $Stage -eq "fill") {
        foreach ($plan in $Plans) {
            if ($plan.files_to_create) {
                $filtered = @()
                foreach ($f in @($plan.files_to_create)) {
                    $fPath = $f.path
                    # Remap backend/ paths to actual src/Server/ paths
                    if ($fPath -match '^backend/') {
                        $fPath = $fPath -replace '^backend/', 'src/Server/Technijian.Api/'
                    }
                    $fullPath = Join-Path $RepoRoot $fPath
                    if ((Test-Path $fullPath) -and (Get-Item $fullPath).Length -gt 200) {
                        $existing = Get-Content $fullPath -Raw -ErrorAction SilentlyContinue
                        if ($existing -and $existing -notmatch '//\s*FILL') {
                            Write-Host "    [PRE-FILTER] Skipping $fPath -- existing real implementation" -ForegroundColor DarkGray
                            continue
                        }
                    }
                    $filtered += $f
                }
                $plan.files_to_create = $filtered
            }
        }
    }

    # Load truncation tracker to detect reqs that need larger model
    $truncTrackerPath = Join-Path $GsdDir "requirements/truncation-tracker.json"
    $truncTracker = @{}
    if (Test-Path $truncTrackerPath) {
        try {
            $ttData = Get-Content $truncTrackerPath -Raw | ConvertFrom-Json
            foreach ($prop in $ttData.PSObject.Properties) { $truncTracker[$prop.Name] = [int]$prop.Value }
        } catch {}
    }

    # Also check requirements matrix for use_large_model flag
    $matrixPath = Join-Path $GsdDir "requirements/requirements-matrix.json"
    $largeModelReqs = @{}
    if (Test-Path $matrixPath) {
        try {
            $matrixData = Get-Content $matrixPath -Raw | ConvertFrom-Json
            foreach ($req in $matrixData.requirements) {
                if ($req.use_large_model -eq $true) {
                    $rid = if ($req.id) { $req.id } else { $req.req_id }
                    $largeModelReqs[$rid] = $true
                }
            }
        } catch {}
    }

    # Build parallel items
    $items = @()
    foreach ($plan in $Plans) {
        $prompt = $promptTemplate.Replace("{{REQ_ID}}", $plan.req_id)
        $prompt = $prompt.Replace("{{PLAN}}", (ConvertTo-CleanJson -InputObject $plan -Depth 5))

        if ($SkeletonResults -and $SkeletonResults.Results -and $SkeletonResults.Results[$plan.req_id]) {
            $prompt = $prompt.Replace("{{SKELETON}}", $SkeletonResults.Results[$plan.req_id].Text)
        }

        # Inject interface-specific conventions
        $interface = if ($plan.interface) { $plan.interface } else { "web" }
        $ifaceConventions = Get-InterfaceConventions -Interface $interface -Config $Config
        $systemPrompt = "$conventions`n`n## Interface: $interface`n$ifaceConventions"

        # Model routing: use Get-NextExecuteModel if available, else fallback to existing logic
        $useModel = $null  # Default: Codex Mini
        $reqId = $plan.req_id
        $routedModel = $null
        try {
            $routedModel = Get-NextExecuteModel -ReqId $reqId -Interface $interface `
                -TruncTracker $truncTracker -LargeModelReqs $largeModelReqs
        } catch {
            # Get-NextExecuteModel not available -- fall through to legacy logic
        }

        if ($routedModel) {
            $useModel = $routedModel
            Write-Host "    [MODEL-ROUTE] $reqId -> $useModel (via Get-NextExecuteModel)" -ForegroundColor Cyan
        } elseif ($largeModelReqs.ContainsKey($reqId) -or ($truncTracker.ContainsKey($reqId) -and $truncTracker[$reqId] -ge 2)) {
            # Fallback: legacy large-model routing for truncation-prone reqs
            $dsKey = [System.Environment]::GetEnvironmentVariable("DEEPSEEK_API_KEY", "User")
            if (-not $dsKey) { $dsKey = [System.Environment]::GetEnvironmentVariable("DEEPSEEK_API_KEY", "Process") }
            if ($dsKey) {
                $useModel = "deepseek-fallback"
                Write-Host "    [LARGE-MODEL] $reqId -> DeepSeek (truncated $($truncTracker[$reqId])x, Codex Mini too small)" -ForegroundColor Cyan
            } else {
                $useModel = "claude-fallback"
                Write-Host "    [LARGE-MODEL] $reqId -> Claude Sonnet (truncated $($truncTracker[$reqId])x, no DeepSeek key)" -ForegroundColor Cyan
            }
        }

        $items += @{
            Id           = $reqId
            SystemPrompt = $systemPrompt
            UserMessage  = $prompt
            Model        = $useModel
        }
    }

    $results = Invoke-CodexMiniParallel -Items $items -MaxConcurrent 2 -Phase "execute-$Stage"

    # Write generated files to disk
    foreach ($reqId in $results.Results.Keys) {
        $r = $results.Results[$reqId]
        if ($r.Success -and $r.Text) {
            Write-GeneratedFiles -RepoRoot $RepoRoot -GsdDir $GsdDir -ReqId $reqId -Output $r.Text
        }
        if ($r.Usage) {
            Add-ApiCallCost -Model $r.Model -Usage $r.Usage -Phase "execute-$Stage" -RequirementId $reqId
        }
    }

    return $results
}

function Invoke-LocalValidatePhase {
    param([string]$GsdDir, [string]$RepoRoot, [PSObject]$ExecuteResults, [array]$Plans)

    $items = @()
    foreach ($plan in $Plans) {
        $filesCreated = @()
        if ($plan.files_to_create) { $filesCreated += $plan.files_to_create | ForEach-Object { $_.path } }
        $interface = if ($plan.interface) { $plan.interface } else { "web" }

        $items += @{
            ReqId           = $plan.req_id
            FilesCreated    = $filesCreated
            AcceptanceTests = $plan.acceptance_tests
            Interface       = $interface
        }
    }

    $confidences = @{}
    foreach ($plan in $Plans) {
        if ($plan.confidence) { $confidences[$plan.req_id] = $plan.confidence }
    }

    return Invoke-BatchLocalValidation -Items $items -RepoRoot $RepoRoot -PlanConfidences $confidences
}

function Invoke-ReviewPhase {
    param(
        [string]$GsdDir, [string]$RepoRoot, [array]$CacheBlocks,
        [array]$FailedItems, [int]$Iteration, [PSObject]$Config
    )

    $promptPath = Join-Path $script:V3Root "prompts/sonnet/06-review.md"
    $promptTemplate = if (Test-Path $promptPath) { Get-Content $promptPath -Raw -Encoding UTF8 } else {
        "Review the failed items below. Provide fix instructions. Output JSON."
    }

    $errorContext = Build-ErrorContext -FailedItems $FailedItems

    # Get git diff for context
    $gitDiff = ""
    try { $gitDiff = git -C $RepoRoot diff 2>&1 | Out-String } catch {}
    if ($gitDiff.Length -gt 8000) { $gitDiff = $gitDiff.Substring(0, 8000) + "`n... (truncated, $($gitDiff.Length) chars total)" }

    $prompt = $promptTemplate.Replace("{{ITERATION}}", "$Iteration")
    $prompt = $prompt.Replace("{{ERROR_CONTEXT}}", $errorContext)
    $prompt = $prompt.Replace("{{GIT_DIFF}}", $gitDiff)

    # Scale review tokens: 1200 per failed item, min 4000, max 24000
    $reviewMaxTokens = [math]::Max(4000, [math]::Min(24000, $FailedItems.Count * 1200))
    Write-Host "    [REVIEW] MaxTokens: $reviewMaxTokens for $($FailedItems.Count) failed items" -ForegroundColor DarkGray

    $result = Invoke-SonnetApi -CacheBlocks $CacheBlocks -UserMessage $prompt `
        -MaxTokens $reviewMaxTokens -UseCache -JsonMode -Phase "review"

    if ($result.Usage) { Add-ApiCallCost -Model $script:SonnetModel -Usage $result.Usage -Phase "review" }

    if ($result.Text) {
        $reviewsDir = Join-Path $GsdDir "iterations/reviews"
        Set-Content (Join-Path $reviewsDir "iteration-$Iteration.json") -Value $result.Text -Encoding UTF8
    }

    return $result.Parsed
}

function Invoke-VerifyPhase {
    param(
        [string]$GsdDir, [string]$RepoRoot, [array]$CacheBlocks,
        [int]$Iteration, [PSObject]$Config, [string]$Mode,
        [hashtable]$BaselineSnapshot = @{},
        [PSObject]$ExecuteResults = $null,
        [PSObject]$ValidateResults = $null,
        [PSObject]$ReviewResults = $null
    )

    $promptPath = Join-Path $script:V3Root "prompts/sonnet/07-verify.md"
    $promptTemplate = if (Test-Path $promptPath) { Get-Content $promptPath -Raw -Encoding UTF8 } else {
        "Update requirement statuses. Calculate health score. Detect drift. Output JSON."
    }

    # Read current health and matrix -- TRUNCATED to prevent token explosion
    # Full matrix can be 200K+ tokens; Verify only needs active (non-satisfied) requirements
    $matrixPath = Join-Path $GsdDir "requirements/requirements-matrix.json"
    $matrixContent = "{}"
    if (Test-Path $matrixPath) {
        try {
            $fullMatrix = Get-Content $matrixPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $allReqs = if ($fullMatrix.requirements) { $fullMatrix.requirements } else { @() }

            # Build a slim matrix with: summary stats + only active requirements
            $activeReqs = @($allReqs | Where-Object { $_.status -in @("not_started", "partial") })

            # Cap active reqs to prevent token explosion (verify prompt + 100 reqs ≈ 8K input tokens)
            $maxVerifyReqs = 100
            $verifyReqs = $activeReqs
            if ($activeReqs.Count -gt $maxVerifyReqs) {
                # Prioritize partial (closest to done) over not_started
                $partialReqs = @($activeReqs | Where-Object { $_.status -eq "partial" }) | Select-Object -First $maxVerifyReqs
                $remaining = $maxVerifyReqs - $partialReqs.Count
                $notStartedReqs = @($activeReqs | Where-Object { $_.status -eq "not_started" }) | Select-Object -First $remaining
                $verifyReqs = @($partialReqs) + @($notStartedReqs)
                Write-Host "    [VERIFY] Capped to $($verifyReqs.Count) of $($activeReqs.Count) active reqs (prioritizing partial)" -ForegroundColor DarkYellow
            }

            $slimMatrix = @{
                _summary = @{
                    total       = $allReqs.Count
                    satisfied   = @($allReqs | Where-Object { $_.status -eq "satisfied" }).Count
                    partial     = @($allReqs | Where-Object { $_.status -eq "partial" }).Count
                    not_started = @($allReqs | Where-Object { $_.status -eq "not_started" }).Count
                }
                requirements = $verifyReqs
            }
            $matrixContent = ConvertTo-CleanJson -InputObject $slimMatrix -Depth 5 -Compress
            Write-Host "    [VERIFY] Slim matrix: $($verifyReqs.Count) verify reqs (of $($allReqs.Count) total, $($activeReqs.Count) active)" -ForegroundColor DarkGray
        }
        catch {
            Write-Host "    [WARN] Could not parse matrix for verify: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }

    $prompt = $promptTemplate.Replace("{{ITERATION}}", "$Iteration")
    $prompt = $prompt.Replace("{{REQUIREMENTS_MATRIX}}", $matrixContent)
    $prompt = $prompt.Replace("{{MODE}}", $Mode)

    # Build evidence block from prior phases (execute, local-validate, review)
    $evidenceBlock = Build-VerifyEvidence -ExecuteResults $ExecuteResults `
        -ValidateResults $ValidateResults -ReviewResults $ReviewResults -RepoRoot $RepoRoot
    if ($evidenceBlock) {
        # Insert evidence after the requirements matrix in the prompt
        $prompt = $prompt + "`n`n$evidenceBlock"
        Write-Host "    [VERIFY] Injected evidence block ($($evidenceBlock.Length) chars)" -ForegroundColor DarkGray
    }

    # Scale verify tokens: 120 per req, min 4000, max 24000
    $verifyReqCount = if ($verifyReqs) { $verifyReqs.Count } else { 50 }
    $verifyMaxTokens = [math]::Max(4000, [math]::Min(24000, $verifyReqCount * 120))
    Write-Host "    [VERIFY] MaxTokens: $verifyMaxTokens" -ForegroundColor DarkGray

    $result = Invoke-SonnetApi -CacheBlocks $CacheBlocks -UserMessage $prompt `
        -MaxTokens $verifyMaxTokens -UseCache -JsonMode -Phase "verify"

    if ($result.Usage) { Add-ApiCallCost -Model $script:SonnetModel -Usage $result.Usage -Phase "verify" }

    # Apply verify results to requirements matrix (THIS WAS MISSING -- root cause of health stall)
    if ($result.Parsed -and $result.Parsed.requirements_status) {
        try {
            $matrixRaw = Get-Content $matrixPath -Raw | ConvertFrom-Json
            $statusMap = @{}
            foreach ($rs in $result.Parsed.requirements_status) {
                if ($rs.req_id -and $rs.status) {
                    $statusMap[$rs.req_id] = $rs.status
                }
            }
            $updated = 0
            $blocked = 0
            foreach ($req in $matrixRaw.requirements) {
                if ($statusMap.ContainsKey($req.id)) {
                    $oldStatus = $req.status
                    $newStatus = $statusMap[$req.id]
                    if ($oldStatus -ne $newStatus) {
                        # NEVER demote satisfied reqs — verify LLM is too conservative
                        # and causes regressions by demoting working code
                        if ($oldStatus -eq "satisfied" -and $newStatus -in @("partial", "not_started")) {
                            $blocked++
                            continue
                        }
                        $req.status = $newStatus
                        $updated++
                    }
                }
            }
            if ($blocked -gt 0) {
                Write-Host "    [VERIFY] Blocked $blocked demotions (satisfied reqs protected)" -ForegroundColor Yellow
            }
            if ($updated -gt 0) {
                $matrixRaw | ConvertTo-Json -Depth 10 | Set-Content $matrixPath -Encoding UTF8
                Write-Host "    [VERIFY] Updated $updated requirement statuses in matrix" -ForegroundColor Green
            } else {
                Write-Host "    [VERIFY] No status changes from verify" -ForegroundColor DarkGray
            }
        }
        catch {
            Write-Host "    [WARN] Failed to apply verify results to matrix: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "    [WARN] Verify returned no requirements_status -- matrix not updated" -ForegroundColor DarkYellow
    }

    # AUTO-PROMOTE: If local validation passed for a req, promote it directly
    # This catches reqs that verify's LLM missed
    if ($ValidateResults -and $ValidateResults.PassItems) {
        try {
            $matrixRaw2 = Get-Content $matrixPath -Raw | ConvertFrom-Json
            $autoPromoted = 0
            foreach ($vr in $ValidateResults.PassItems) {
                if ($vr.ReqId) {
                    $matchReq = $matrixRaw2.requirements | Where-Object { $_.id -eq $vr.ReqId -and $_.status -ne "satisfied" }
                    if ($matchReq) {
                        $matchReq.status = "satisfied"
                        $autoPromoted++
                    }
                }
            }
            if ($autoPromoted -gt 0) {
                $matrixRaw2.summary.satisfied = @($matrixRaw2.requirements | Where-Object { $_.status -eq "satisfied" }).Count
                $matrixRaw2 | ConvertTo-Json -Depth 10 | Set-Content $matrixPath -Encoding UTF8
                Write-Host "    [AUTO-PROMOTE] $autoPromoted reqs promoted to satisfied (validation passed)" -ForegroundColor Green
            }
        } catch {
            Write-Host "    [WARN] Auto-promote failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }

    # Update health
    $health = Update-HealthScore -GsdDir $GsdDir
    return @{ HealthScore = $health.score; Parsed = $result.Parsed }
}

function Invoke-SpecFixPhase {
    param([string]$GsdDir, [string]$RepoRoot, [array]$CacheBlocks, [PSObject]$Config)

    $promptPath = Join-Path $script:V3Root "prompts/sonnet/08-spec-fix.md"
    $prompt = if (Test-Path $promptPath) { Get-Content $promptPath -Raw -Encoding UTF8 } else {
        "Resolve spec conflicts. Output JSON with resolutions."
    }

    $result = Invoke-SonnetApi -CacheBlocks $CacheBlocks -UserMessage $prompt `
        -MaxTokens 4000 -UseCache -JsonMode -Phase "spec-fix"

    if ($result.Usage) { Add-ApiCallCost -Model $script:SonnetModel -Usage $result.Usage -Phase "spec-fix" }

    # Invalidate cache after spec fix
    if ($result.Parsed -and $result.Parsed.cache_invalidation) {
        Write-Host "  [CACHE] Spec fix invalidated cache block 2" -ForegroundColor Yellow
    }
}

# ============================================================
# ANTI-PLATEAU HELPERS
# ============================================================

function Get-StallBreakingAction {
    <#
    .SYNOPSIS
        Determines what action to take when the pipeline is stalled.
        Returns an action object with Action = "escalate", "skip", or "continue".
    #>
    param(
        [string]$GsdDir,
        [int]$ConsecutiveZero = 0
    )

    # Read health history to understand stall pattern
    $historyPath = Join-Path $GsdDir "health/health-history.jsonl"
    if (-not (Test-Path $historyPath)) {
        return @{ Action = "continue"; Reason = "No history" }
    }

    try {
        $lines = Get-Content $historyPath -Encoding UTF8 | Where-Object { $_.Trim() }
        $entries = $lines | ForEach-Object { $_ | ConvertFrom-Json }
        $recent = $entries | Select-Object -Last 5
    } catch {
        return @{ Action = "continue"; Reason = "Cannot parse history" }
    }

    # Decision logic based on consecutive zero-delta count
    if ($ConsecutiveZero -ge 5) {
        return @{ Action = "force_break"; Reason = "5+ consecutive zero-delta iterations" }
    }
    if ($ConsecutiveZero -ge 3) {
        return @{ Action = "skip"; Reason = "3+ consecutive stalls -- defer stuck reqs" }
    }
    if ($ConsecutiveZero -ge 2) {
        return @{ Action = "escalate"; Reason = "2+ consecutive stalls -- try larger model" }
    }

    return @{ Action = "continue"; Reason = "Below threshold" }
}

function Get-NextExecuteModel {
    <#
    .SYNOPSIS
        Determines which model to use for executing a given requirement.
        Returns model identifier string or $null for default (Codex Mini).
    #>
    param(
        [string]$ReqId,
        [string]$Interface = "web",
        [hashtable]$TruncTracker = @{},
        [hashtable]$LargeModelReqs = @{}
    )

    # Priority 1: Explicitly flagged for large model (anti-plateau escalation or truncation)
    if ($LargeModelReqs.ContainsKey($ReqId)) {
        $dsKey = [System.Environment]::GetEnvironmentVariable("DEEPSEEK_API_KEY", "User")
        if (-not $dsKey) { $dsKey = [System.Environment]::GetEnvironmentVariable("DEEPSEEK_API_KEY", "Process") }
        if ($dsKey) { return "deepseek-fallback" }
        return "claude-fallback"
    }

    # Priority 2: Truncation history (2+ truncations -> larger model)
    if ($TruncTracker.ContainsKey($ReqId) -and $TruncTracker[$ReqId] -ge 2) {
        $dsKey = [System.Environment]::GetEnvironmentVariable("DEEPSEEK_API_KEY", "User")
        if (-not $dsKey) { $dsKey = [System.Environment]::GetEnvironmentVariable("DEEPSEEK_API_KEY", "Process") }
        if ($dsKey) { return "deepseek-fallback" }
        return "claude-fallback"
    }

    # Priority 3: Interface-based routing (database reqs may benefit from specific models)
    # Default: return $null (Codex Mini)
    return $null
}

# ============================================================
# HELPERS
# ============================================================

function Build-VerifyEvidence {
    <#
    .SYNOPSIS
        Build a concise evidence block from execute, validate, and review results
        so the verify phase can make informed status decisions.
    .DESCRIPTION
        Without this evidence, the verify phase has no knowledge of what happened
        during the current iteration and returns stale statuses.
        Capped at ~2000 tokens (~6000 chars) to stay within budget.
    #>
    param(
        [PSObject]$ExecuteResults,
        [PSObject]$ValidateResults,
        [PSObject]$ReviewResults,
        [string]$RepoRoot
    )

    $evidence = @()
    $maxChars = 6000  # ~2000 tokens

    # --- Execute Results ---
    if ($ExecuteResults -and $ExecuteResults.Results) {
        $evidence += "## Execute Phase Evidence"
        $evidence += "Completed: $($ExecuteResults.Completed) | Failed: $($ExecuteResults.Failed) | Total: $($ExecuteResults.Total)"
        $evidence += ""

        $filesCreated = @()
        $filesModified = @()
        $execFailures = @()

        foreach ($reqId in $ExecuteResults.Results.Keys) {
            $r = $ExecuteResults.Results[$reqId]
            if ($r.Success -and $r.Text) {
                # Extract file paths from the output (--- FILE: path --- markers)
                $fileMatches = [regex]::Matches($r.Text, '(?m)^---\s*FILE:\s*(.+?)\s*---\s*$')
                foreach ($fm in $fileMatches) {
                    $fPath = $fm.Groups[1].Value.Trim()
                    $fullPath = Join-Path $RepoRoot $fPath
                    if (Test-Path $fullPath) {
                        $filesCreated += "$reqId : $fPath"
                    }
                }
                if ($fileMatches.Count -eq 0) {
                    $filesModified += "$reqId : (raw output, no file markers)"
                }
            }
            elseif (-not $r.Success) {
                $execFailures += "$reqId : execute failed"
            }
        }

        if ($filesCreated.Count -gt 0) {
            $evidence += "### Files Written"
            # Cap at 40 entries
            $cap = [math]::Min($filesCreated.Count, 40)
            $evidence += ($filesCreated | Select-Object -First $cap | ForEach-Object { "- $_" })
            if ($filesCreated.Count -gt $cap) {
                $evidence += "- ... and $($filesCreated.Count - $cap) more"
            }
        }

        if ($execFailures.Count -gt 0) {
            $evidence += ""
            $evidence += "### Execute Failures"
            $evidence += ($execFailures | Select-Object -First 20 | ForEach-Object { "- $_" })
        }
        $evidence += ""
    }

    # --- Local Validation Results ---
    if ($ValidateResults) {
        $evidence += "## Local Validation Evidence"
        $evidence += "Passed: $($ValidateResults.TotalPassed) | Failed: $($ValidateResults.TotalFailed)"
        $evidence += ""

        # Passed items (just list req_ids)
        $passedIds = @()
        if ($ValidateResults.PassItems) {
            $passedIds += $ValidateResults.PassItems | ForEach-Object { $_.ReqId }
        }
        if ($ValidateResults.SkipReviewItems) {
            $passedIds += $ValidateResults.SkipReviewItems | ForEach-Object { $_.ReqId }
        }
        if ($passedIds.Count -gt 0) {
            $evidence += "### Passed (local validation)"
            $evidence += ($passedIds | Select-Object -First 50 | ForEach-Object { "- $_ : PASS" })
            $evidence += ""
        }

        # Failed items with reasons
        if ($ValidateResults.FailItems -and $ValidateResults.FailItems.Count -gt 0) {
            $evidence += "### Failed (local validation)"
            foreach ($failItem in ($ValidateResults.FailItems | Select-Object -First 20)) {
                $reasons = @()
                if ($failItem.Result -and $failItem.Result.Failures) {
                    $reasons = $failItem.Result.Failures | ForEach-Object {
                        $msg = "[$($_.type)] $($_.message)"
                        # Truncate individual failure output
                        if ($_.output -and $_.output.Length -gt 200) {
                            $msg += " (output: $($_.output.Substring(0, 200))...)"
                        } elseif ($_.output) {
                            $msg += " (output: $($_.output))"
                        }
                        $msg
                    }
                }
                $reasonText = if ($reasons.Count -gt 0) { $reasons -join "; " } else { "unknown failure" }
                $evidence += "- $($failItem.ReqId) : FAIL - $reasonText"
            }
            $evidence += ""
        }
    }

    # --- Review Results ---
    if ($ReviewResults) {
        $evidence += "## Review Phase Evidence"

        # ReviewResults is parsed JSON from Sonnet -- structure varies but typically has reviews array
        if ($ReviewResults.reviews) {
            foreach ($review in ($ReviewResults.reviews | Select-Object -First 20)) {
                $rid = if ($review.req_id) { $review.req_id } else { "unknown" }
                $status = if ($review.status) { $review.status } else { "reviewed" }
                $issues = ""
                if ($review.issues) {
                    $issues = ($review.issues | Select-Object -First 3 | ForEach-Object {
                        if ($_ -is [string]) { $_ } else { $_.message }
                    }) -join "; "
                } elseif ($review.summary) {
                    $issues = $review.summary
                }

                $line = "- ${rid}: $status"
                if ($issues) { $line += " - $issues" }
                $evidence += $line
            }
        } elseif ($ReviewResults.findings) {
            foreach ($finding in ($ReviewResults.findings | Select-Object -First 20)) {
                $rid = if ($finding.req_id) { $finding.req_id } else { "unknown" }
                $severity = if ($finding.severity) { $finding.severity } else { "info" }
                $msg = if ($finding.message) { $finding.message } else { $finding.description }
                $evidence += "- ${rid}: [$severity] $msg"
            }
        } else {
            # Fallback: dump a compact JSON summary
            $reviewJson = ConvertTo-CleanJson -InputObject $ReviewResults -Depth 5 -Compress
            if ($reviewJson.Length -gt 1500) {
                $reviewJson = $reviewJson.Substring(0, 1500) + "..."
            }
            $evidence += $reviewJson
        }
        $evidence += ""
    }

    # Join and cap total size
    if ($evidence.Count -eq 0) { return $null }

    $evidenceText = "# Iteration Evidence (from prior phases)`n`n" + ($evidence -join "`n")

    if ($evidenceText.Length -gt $maxChars) {
        $evidenceText = $evidenceText.Substring(0, $maxChars) + "`n... (evidence truncated at $maxChars chars)"
    }

    return $evidenceText
}

function Get-InterfaceConventions {
    param([string]$Interface, [PSObject]$Config)

    $conventions = $Config.interface_conventions
    if (-not $conventions) { return "" }

    $iface = $conventions.$Interface
    if (-not $iface) { return "" }

    return ($iface | ConvertTo-Json -Depth 5)
}

function Write-GeneratedFiles {
    param([string]$RepoRoot, [string]$GsdDir, [string]$ReqId, [string]$Output)

    # Parse file markers from Codex output: --- FILE: path/to/file.ts ---
    $filePattern = '(?m)^---\s*FILE:\s*(.+?)\s*---\s*$'
    $fileMatches = [regex]::Matches($Output, $filePattern)

    if ($fileMatches.Count -eq 0) {
        # Single file output -- save as raw
        $logPath = Join-Path $GsdDir "iterations/execution-log/$ReqId.txt"
        Set-Content $logPath -Value $Output -Encoding UTF8
        return
    }

    # Path remapping: plan/Codex uses "backend/" but real project is "src/Server/Technijian.Api/"
    # This mapping ensures generated code lands in the actual build path
    $pathMappings = @(
        @{ From = "^backend/";  To = "src/Server/Technijian.Api/" }
    )

    for ($i = 0; $i -lt $fileMatches.Count; $i++) {
        $filePath = $fileMatches[$i].Groups[1].Value.Trim()

        # Apply path remapping
        foreach ($mapping in $pathMappings) {
            if ($filePath -match $mapping.From) {
                $originalPath = $filePath
                $filePath = $filePath -replace $mapping.From, $mapping.To
                Write-Host "      [REMAP] $originalPath -> $filePath" -ForegroundColor DarkCyan
                break
            }
        }
        $startIdx = $fileMatches[$i].Index + $fileMatches[$i].Length

        $endIdx = if ($i + 1 -lt $fileMatches.Count) { $fileMatches[$i + 1].Index } else { $Output.Length }
        $content = $Output.Substring($startIdx, $endIdx - $startIdx).Trim()

        # Strip code fences if present
        if ($content -match '^```\w*\n([\s\S]*?)\n```$') { $content = $Matches[1] }

        # ============================================================
        # SMART WRITE GUARD -- 3-layer defense against disease
        # ============================================================

        # Layer 0: Namespace remapping for backend C# files
        if ($filePath -like "src/Server/Technijian.Api/*.cs") {
            $content = $content -replace 'namespace\s+backend\.', 'namespace Technijian.Api.'
            $content = $content -replace 'namespace\s+backend\b', 'namespace Technijian.Api'
            $content = $content -replace 'using\s+backend\.', 'using Technijian.Api.'
        }

        # Layer 1: Auto-fix known namespace diseases (runs on ALL .cs files before writing)
        if ($filePath -like "*.cs") {
            # Disease: LLM generates wrong namespace for IDbConnectionFactory
            #   "using Technijian.Api.Data;" when IDbConnectionFactory is in TCAI.Data
            #   "Data.IDbConnectionFactory" qualified refs from wrong namespace
            $content = $content -replace 'using\s+Technijian\.Api\.Tenants\s*;', 'using Technijian.Api.MultiTenancy;'
            $content = $content -replace 'using\s+Technijian\.Api\.Gdpr\s*;', 'using Technijian.Api.Compliance;'

            # Disease: LLM references IDbConnectionFactory without TCAI.Data using
            #   Only fix if file actually references IDbConnectionFactory AND doesn't already have TCAI.Data
            if ($content -match 'IDbConnectionFactory' -and $content -notmatch 'using\s+TCAI\.Data\s*;' -and $content -notmatch 'namespace\s+TCAI\.Data') {
                # Add using TCAI.Data after the last using statement
                if ($content -match '(?m)(^using\s+[^;]+;\s*\n)(?!using)') {
                    $content = $content -replace '(?m)(^using\s+[^;]+;\s*\n)(?!using)', "`$1using TCAI.Data;`n"
                    Write-Host "      [AUTO-FIX] Added 'using TCAI.Data' to $filePath" -ForegroundColor Yellow
                }
                # Fix qualified "Data.IDbConnectionFactory" refs to unqualified (since we added using)
                $content = $content -replace '(?<!\w)Data\.IDbConnectionFactory', 'IDbConnectionFactory'
            }

            # Disease: Controllers inheriting TcaiControllerBase without the using
            if ($content -match ':\s*TcaiControllerBase' -and $content -notmatch 'using\s+Technijian\.Api\.Controllers\s*;' -and $content -notmatch 'namespace\s+Technijian\.Api\.Controllers') {
                if ($content -match '(?m)(^using\s+[^;]+;\s*\n)(?!using)') {
                    $content = $content -replace '(?m)(^using\s+[^;]+;\s*\n)(?!using)', "`$1using Technijian.Api.Controllers;`n"
                    Write-Host "      [AUTO-FIX] Added 'using Technijian.Api.Controllers' to $filePath" -ForegroundColor Yellow
                }
            }

            # Disease: LLM uses System.Data.SqlClient instead of Microsoft.Data.SqlClient
            if ($content -match 'System\.Data\.SqlClient') {
                $content = $content -replace 'using\s+System\.Data\.SqlClient\s*;', 'using Microsoft.Data.SqlClient;'
                $content = $content -replace 'System\.Data\.SqlClient\.', 'Microsoft.Data.SqlClient.'
                Write-Host "      [AUTO-FIX] Replaced System.Data.SqlClient with Microsoft.Data.SqlClient in $filePath" -ForegroundColor Yellow
            }

            # Disease: LLM uses TcaiPlatform.GDPR instead of Technijian.Api.GDPR
            $content = $content -replace 'using\s+TcaiPlatform\.GDPR(\.Models)?\s*;', 'using Technijian.Api.GDPR;'

            # Disease: LLM uses DataLevel instead of DataClassification
            $content = $content -replace '\bDataLevel\b', 'DataClassification'

            # Disease: LLM uses namespace TCAI.Controllers instead of Technijian.Api.Controllers
            $content = $content -replace 'namespace\s+TCAI\.Controllers\s*;', 'namespace Technijian.Api.Controllers;'
        }

        $fullPath = Join-Path $RepoRoot $filePath
        $dir = Split-Path $fullPath -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

        # Layer 1b-pre: Dynamic skip list -- files blocked 2+ times are permanently skipped
        $skipListPath = Join-Path $GsdDir "blocked-files-skip.json"
        $skipList = @{}
        if (Test-Path $skipListPath) {
            try {
                $slData = Get-Content $skipListPath -Raw | ConvertFrom-Json
                foreach ($prop in $slData.PSObject.Properties) { $skipList[$prop.Name] = [int]$prop.Value }
            } catch {}
        }
        if ($skipList.ContainsKey($filePath) -and $skipList[$filePath] -ge 2) {
            Write-Host "      [SKIP-LIST] $filePath -- permanently skipped (blocked $($skipList[$filePath])x)" -ForegroundColor DarkYellow
            continue
        }

        # Layer 1b: Block duplicate/disease files that conflict with existing architecture
        $blockedFiles = @(
            "src/Server/Technijian.Api/Infrastructure/ISqlConnectionFactory.cs",
            "src/Server/Technijian.Api/Infrastructure/SqlConnectionFactory.cs",
            "src/Server/Technijian.Api/GDPR/ConsentRecord.cs",
            "src/Server/Technijian.Api/GDPR/ErasureRequestResult.cs",
            "src/Server/Technijian.Api/GDPR/GdprExportResult.cs",
            "src/Server/Technijian.Api/Program.cs",
            "src/Server/Technijian.Api/GDPR/IGdprService.cs",
            "src/Server/Technijian.Api/GDPR/GdprService.cs",
            "tests/backend/unit/GdprServiceTests.cs",
            "tests/backend/unit/KeyVaultServiceTests.cs",
            "src/Server/Technijian.Api/Data/SqlDbConnectionFactory.cs",
            "src/Server/Technijian.Api/Data/DapperExtensions.cs",
            "src/Server/Technijian.Api/Data/DbConnectionFactory.cs",
            "src/Server/Technijian.Api/Security/IKeyVaultService.cs",
            "src/Server/Technijian.Api/Security/KeyVaultService.cs",
            "src/Server/Technijian.Api/Retention/IRetentionService.cs",
            "src/Server/Technijian.Api/MultiTenancy/ITenantCacheService.cs",
            "src/Server/Technijian.Api/MultiTenancy/TenantCacheService.cs",
            "src/Server/Technijian.Api/Data/SqlConnectionFactory.cs",
            "src/Server/Technijian.Api/Services/ITenantCacheService.cs",
            "src/Server/Technijian.Api/Services/TenantCacheService.cs",
            "src/Server/Technijian.Api/Services/RetentionService.cs",
            "src/Server/Technijian.Api/Compliance/ComplianceControlService.cs",
            "src/Server/Technijian.Api/Compliance/IComplianceControlService.cs",
            "src/Server/Technijian.Api/Security/HipaaGuardAttribute.cs",
            "src/Server/Technijian.Api/Services/ISoftDeleteService.cs",
            "src/Server/Technijian.Api/Services/SoftDeleteService.cs",
            "src/Server/Technijian.Api/Compliance/ComplianceService.cs",
            "src/Server/Technijian.Api/Security/HipaaControlsService.cs",
            "src/Server/Technijian.Api/Services/DataRetentionService.cs",
            "src/Server/Technijian.Api/Services/SoftDeleteOrchestrationService.cs",
            "src/Server/Technijian.Api/Security/KeyVaultSecretNames.cs",
            "src/Server/Technijian.Api/Security/KeyVaultHealthCheck.cs",
            "src/Server/Technijian.Api/Compliance/CcpaService.cs",
            "src/Server/Technijian.Api/Compliance/HipaaService.cs",
            "src/Server/Technijian.Api/Health/SqlHealthCheck.cs",
            "src/web/package.json",
            "src/web/src/lib/zodSchemas.ts",
            "src/Server/Technijian.Api/Repositories/RepositoryBase.cs",
            "src/Server/Technijian.Api/Repositories/IRepositoryBase.cs",
            "src/shared/api/client.ts",
            "src/web/main.tsx",
            "src/Server/Technijian.Api/Compliance/CcpaControlsService.cs",
            "src/Server/Technijian.Api/Compliance/GdprControlsService.cs",
            "src/Server/Technijian.Api/Compliance/Models/ComplianceEvent.cs",
            "src/Server/Technijian.Api/Services/RetentionPolicyService.cs",
            "src/Server/Technijian.Api/Services/RetentionPolicyHostedService.cs",
            "src/Server/Technijian.Api/BackgroundJobs/RetentionEnforcementJob.cs",
            "src/Server/Technijian.Api/Infrastructure/VectorStoreTenantHelper.cs",
            "src/Server/Technijian.Api/Infrastructure/TenantContextAccessor.cs",
            "src/Server/Technijian.Api/Infrastructure/CacheKeyHelper.cs",
            "src/Server/Technijian.Api/Infrastructure/FileStorageTenantHelper.cs",
            "src/Server/Technijian.Api/Compliance/HipaaControlsService.cs",
            "src/Server/Technijian.Api/Storage/BlobStorageService.cs",
            "src/Server/Technijian.Api/Storage/IBlobStorageService.cs",
            "src/Server/Technijian.Api/backend.csproj",
            "src/Server/Technijian.Api/Data/DapperOptions.cs",
            "src/Server/Technijian.Api/Data/SqlExceptionMapper.cs"
        )
        if ($filePath -in $blockedFiles) {
            Write-Host "      [BLOCKED] $filePath -- conflicts with existing architecture (TCAI.Data pattern)" -ForegroundColor Red
            # Track block count for dynamic skip list
            if (-not $skipList.ContainsKey($filePath)) { $skipList[$filePath] = 0 }
            $skipList[$filePath]++
            $skipList | ConvertTo-Json -Depth 3 | Set-Content $skipListPath -Encoding UTF8
            continue
        }

        # Layer 2: Protected interfaces -- NEVER overwrite (contract stability)
        $protectedInterfaces = @(
            "src/Server/Technijian.Api/Data/IDbConnectionFactory.cs",
            "src/Server/Technijian.Api/Security/IKeyVaultService.cs",
            "src/Server/Technijian.Api/Controllers/TcaiControllerBase.cs",
            "src/Server/Technijian.Api/Compliance/IComplianceService.cs",
            "src/Server/Technijian.Api/GDPR/IGdprService.cs",
            "src/Server/Technijian.Api/Program.cs",
            "src/Server/Technijian.Api/Retention/IRetentionService.cs",
            "src/Server/Technijian.Api/SoftDelete/ISoftDeleteService.cs",
            "src/Server/Technijian.Api/Compliance/ComplianceControlsRegistry.cs",
            "src/Server/Technijian.Api/Compliance/ComplianceOptions.cs",
            "src/Server/Technijian.Api/Auth/JwtTokenService.cs",
            "src/Server/Technijian.Api/Auth/TokenBlacklistService.cs",
            "src/Server/Technijian.Api/Monitoring/GoLiveMonitoringService.cs",
            "src/Server/Technijian.Api/Monitoring/ICouncilMetricsService.cs",
            "src/Server/Technijian.Api/Monitoring/CouncilMetricsService.cs",
            "src/shared/api/mutator.ts",
            "src/Server/Technijian.Api/Attributes/RequireSessionTokenAttribute.cs",
            "src/Server/Technijian.Api/Middleware/SessionTokenValidationMiddleware.cs",
            "src/shared/api/index.ts",
            "src/shared/testing/zodOpenApiValidator.ts",
            "vitest.config.ts"
        )
        if ($filePath -in $protectedInterfaces -and (Test-Path $fullPath)) {
            Write-Host "      [PROTECTED] $filePath -- tracked interface/base class, skipping overwrite" -ForegroundColor Cyan
            continue
        }

        # Layer 3: Smart implementation guard -- only write if compatible with existing interfaces
        if ((Test-Path $fullPath)) {
            $existingContent = Get-Content $fullPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            $newHasFill = $content -match '//\s*FILL'
            $existingHasFill = $existingContent -match '//\s*FILL'
            $existingSize = if ($existingContent) { $existingContent.Length } else { 0 }

            # Guard 3a: Don't overwrite real implementations with FILL stubs
            if ($newHasFill -and -not $existingHasFill -and $existingSize -gt 200) {
                Write-Host "      [SKIP] $filePath -- existing file has real implementation, new content has FILL stubs" -ForegroundColor DarkYellow
                continue
            }

            # Guard 3b: Block writes that shrink real files by >35% (likely truncated/incomplete output)
            if (-not $newHasFill -and -not $existingHasFill -and $existingSize -gt 500) {
                $shrinkRatio = if ($existingSize -gt 0) { $content.Length / $existingSize } else { 1 }
                if ($shrinkRatio -lt 0.65) {
                    Write-Host "      [BLOCKED] $filePath -- new content is $([math]::Round((1-$shrinkRatio)*100))% smaller ($existingSize -> $($content.Length) chars), likely truncated" -ForegroundColor Red
                    # Track block count for dynamic skip list
                    if (-not $skipList.ContainsKey($filePath)) { $skipList[$filePath] = 0 }
                    $skipList[$filePath]++
                    $skipList | ConvertTo-Json -Depth 3 | Set-Content $skipListPath -Encoding UTF8
                    continue
                }
                if ($existingSize -gt $content.Length) {
                    Write-Host "      [WARN] $filePath -- overwriting larger existing file ($existingSize -> $($content.Length) chars)" -ForegroundColor DarkYellow
                }
            }
        }

        Set-Content $fullPath -Value $content -Encoding UTF8
        Write-Host "      [WRITE] $filePath" -ForegroundColor DarkGray
    }
}

# ============================================================
# EXISTING CODEBASE MODE FUNCTIONS
# ============================================================

function Invoke-DeepRequirementsExtraction {
    <#
    .SYNOPSIS
        Reads spec docs from the repo and calls Sonnet with a high token limit
        to extract granular requirements for existing codebases.
    .PARAMETER GsdDir
        Path to the .gsd directory.
    .PARAMETER RepoRoot
        Repository root path.
    .PARAMETER CacheBlocks
        Cache prefix blocks for Sonnet API calls.
    .PARAMETER Config
        Global config object.
    .RETURNS
        Count of requirements extracted.
    #>
    param(
        [Parameter(Mandatory)][string]$GsdDir,
        [Parameter(Mandatory)][string]$RepoRoot,
        [array]$CacheBlocks,
        [PSObject]$Config
    )

    $ecmConfig = $Config.existing_codebase_mode
    $maxTokens = if ($ecmConfig.deep_extraction_max_tokens) { $ecmConfig.deep_extraction_max_tokens } else { 32000 }

    Write-Host "`n--- Deep Requirements Extraction (Existing Codebase Mode) ---" -ForegroundColor Yellow

    # Collect spec documents from standard locations
    $specDirs = @("docs", "design", "specs")
    $specContent = [System.Text.StringBuilder]::new()
    $fileCount = 0

    foreach ($dir in $specDirs) {
        $dirPath = Join-Path $RepoRoot $dir
        if (Test-Path $dirPath) {
            $specFiles = Get-ChildItem -Path $dirPath -Recurse -Include "*.md","*.txt","*.json","*.yaml","*.yml" -ErrorAction SilentlyContinue
            foreach ($f in $specFiles) {
                if ($f.Length -gt 0 -and $f.Length -lt 500000) {
                    $content = Get-Content $f.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                    if ($content) {
                        $relativePath = $f.FullName.Substring($RepoRoot.Length + 1)
                        [void]$specContent.AppendLine("--- FILE: $relativePath ---")
                        [void]$specContent.AppendLine($content)
                        [void]$specContent.AppendLine("")
                        $fileCount++
                    }
                }
            }
        }
    }

    Write-Host "  Collected $fileCount spec files from: $($specDirs -join ', ')" -ForegroundColor DarkGray

    if ($fileCount -eq 0) {
        Write-Host "  [WARN] No spec documents found. Skipping deep extraction." -ForegroundColor DarkYellow
        return 0
    }

    # Build the extraction prompt
    $extractionPrompt = @"
You are analyzing an EXISTING codebase's specification documents to extract granular requirements.

## Spec Documents
$($specContent.ToString())

## Instructions
Extract every discrete, testable requirement from these specs. For each requirement:
1. Assign a unique ID (REQ-001, REQ-002, etc.)
2. Write a clear, specific description
3. Identify the interface (web, backend, shared, mobile, browser, agent)
4. List the expected source files that would implement it
5. Set initial status to "not_started" (verification phase will update)
6. Set priority (critical, high, medium, low)

Output JSON:
{
  "requirements": [
    {
      "id": "REQ-001",
      "description": "...",
      "interface": "web|backend|shared|...",
      "expected_files": ["path/to/file.ts"],
      "status": "not_started",
      "priority": "high",
      "acceptance_criteria": ["criterion 1", "criterion 2"]
    }
  ],
  "total_count": N,
  "extraction_notes": "..."
}
"@

    # Call Sonnet for extraction
    $result = Invoke-SonnetApi -SystemPrompt "You are a requirements extraction specialist." `
        -UserMessage $extractionPrompt -CacheBlocks $CacheBlocks `
        -MaxTokens $maxTokens -JsonMode $true

    if ($result.Usage) {
        Add-ApiCallCost -Model $script:SonnetModel -Usage $result.Usage -Phase "deep-extraction"
    }

    if (-not $result.Success -or -not $result.Text) {
        Write-Host "  [ERROR] Deep extraction API call failed" -ForegroundColor Red
        return 0
    }

    # Parse and save requirements
    try {
        $extracted = $result.Text | ConvertFrom-Json

        # Ensure requirements directory exists
        $reqDir = Join-Path $GsdDir "requirements"
        if (-not (Test-Path $reqDir)) { New-Item -Path $reqDir -ItemType Directory -Force | Out-Null }

        $matrixPath = Join-Path $reqDir "requirements-matrix.json"

        # If matrix exists, merge; otherwise create fresh
        if (Test-Path $matrixPath) {
            $existing = Get-Content $matrixPath -Raw | ConvertFrom-Json
            $existingIds = @{}
            foreach ($req in $existing.requirements) {
                $rid = if ($req.id) { $req.id } else { $req.req_id }
                $existingIds[$rid] = $true
            }
            $newReqs = @($extracted.requirements | Where-Object {
                $rid = if ($_.id) { $_.id } else { $_.req_id }
                -not $existingIds.ContainsKey($rid)
            })
            if ($newReqs.Count -gt 0) {
                $allReqs = [System.Collections.ArrayList]@($existing.requirements)
                foreach ($nr in $newReqs) { [void]$allReqs.Add($nr) }
                $existing.requirements = $allReqs.ToArray()
                $existing | ConvertTo-Json -Depth 10 | Set-Content $matrixPath -Encoding UTF8
                Write-Host "  [MERGE] Added $($newReqs.Count) new requirements (total: $($allReqs.Count))" -ForegroundColor Green
            } else {
                Write-Host "  [MERGE] No new requirements to add (all $($extracted.requirements.Count) already exist)" -ForegroundColor DarkGray
            }
            return $existing.requirements.Count
        } else {
            $extracted | ConvertTo-Json -Depth 10 | Set-Content $matrixPath -Encoding UTF8
            $count = $extracted.requirements.Count
            Write-Host "  [CREATED] Requirements matrix with $count requirements" -ForegroundColor Green
            return $count
        }
    } catch {
        Write-Host "  [ERROR] Failed to parse extraction results: $_" -ForegroundColor Red
        return 0
    }
}


function Invoke-CodeInventory {
    <#
    .SYNOPSIS
        Scans the repo for source files, detects stubs, and builds a code inventory.
    .PARAMETER RepoRoot
        Repository root path.
    .PARAMETER Config
        Global config object.
    .RETURNS
        Inventory object with files, stubs, and summary stats.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [PSObject]$Config
    )

    $ecmConfig = $Config.existing_codebase_mode
    $stubPatterns = if ($ecmConfig.stub_detection_patterns) {
        @($ecmConfig.stub_detection_patterns)
    } else {
        @("// TODO", "// FILL", "throw NotImplementedException", "throw new NotImplementedException")
    }

    Write-Host "`n--- Code Inventory (Existing Codebase Mode) ---" -ForegroundColor Yellow

    # Source file extensions to scan
    $sourceExtensions = @("*.cs", "*.ts", "*.tsx", "*.js", "*.jsx", "*.sql", "*.css", "*.scss")
    $excludeDirs = @("node_modules", "bin", "obj", "dist", "build", ".vs", ".idea", ".gsd", ".git")

    $inventory = @{
        files        = @()
        stubs        = @()
        by_interface = @{}
        total_files  = 0
        total_lines  = 0
        stub_count   = 0
        scanned_at   = (Get-Date).ToString("o")
    }

    foreach ($ext in $sourceExtensions) {
        $files = Get-ChildItem -Path $RepoRoot -Recurse -Filter $ext -ErrorAction SilentlyContinue |
            Where-Object {
                $skip = $false
                foreach ($exDir in $excludeDirs) {
                    if ($_.FullName -match [regex]::Escape($exDir)) { $skip = $true; break }
                }
                -not $skip
            }

        foreach ($f in $files) {
            $relativePath = $f.FullName.Substring($RepoRoot.Length + 1).Replace("\", "/")
            $lineCount = 0
            $stubsFound = @()

            try {
                $content = Get-Content $f.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                if ($content) {
                    $lineCount = ($content -split "`n").Count

                    # Detect stubs
                    foreach ($pattern in $stubPatterns) {
                        if ($content -match [regex]::Escape($pattern)) {
                            $stubsFound += $pattern
                        }
                    }
                }
            } catch {}

            # Determine interface from path
            $interface = "unknown"
            if ($relativePath -match '^src/web/') { $interface = "web" }
            elseif ($relativePath -match '^src/Server/' -or $relativePath -match '^backend/') { $interface = "backend" }
            elseif ($relativePath -match '^src/shared/') { $interface = "shared" }
            elseif ($relativePath -match '^src/mobile/') { $interface = "mobile" }
            elseif ($relativePath -match '^src/browser/') { $interface = "browser" }
            elseif ($relativePath -match '^src/agent/') { $interface = "agent" }
            elseif ($relativePath -match '^src/mcp-admin/') { $interface = "mcp-admin" }

            $fileEntry = @{
                path      = $relativePath
                lines     = $lineCount
                interface = $interface
                is_stub   = ($stubsFound.Count -gt 0)
                stubs     = $stubsFound
                size      = $f.Length
            }

            $inventory.files += $fileEntry
            $inventory.total_files++
            $inventory.total_lines += $lineCount

            if ($stubsFound.Count -gt 0) {
                $inventory.stubs += @{
                    path     = $relativePath
                    patterns = $stubsFound
                }
                $inventory.stub_count++
            }

            # Track by interface
            if (-not $inventory.by_interface.ContainsKey($interface)) {
                $inventory.by_interface[$interface] = @{ files = 0; lines = 0; stubs = 0 }
            }
            $inventory.by_interface[$interface].files++
            $inventory.by_interface[$interface].lines += $lineCount
            if ($stubsFound.Count -gt 0) { $inventory.by_interface[$interface].stubs++ }
        }
    }

    Write-Host "  Total files: $($inventory.total_files) | Total lines: $($inventory.total_lines) | Stubs: $($inventory.stub_count)" -ForegroundColor DarkGray
    foreach ($iface in $inventory.by_interface.Keys | Sort-Object) {
        $stats = $inventory.by_interface[$iface]
        Write-Host "    $iface`: $($stats.files) files, $($stats.lines) lines, $($stats.stubs) stubs" -ForegroundColor DarkGray
    }

    # Save inventory to disk
    $GsdDir = Join-Path $RepoRoot ".gsd"
    if (-not (Test-Path $GsdDir)) { New-Item -Path $GsdDir -ItemType Directory -Force | Out-Null }
    $inventoryPath = Join-Path $GsdDir "code-inventory.json"
    $inventory | ConvertTo-Json -Depth 5 | Set-Content $inventoryPath -Encoding UTF8
    Write-Host "  [SAVED] $inventoryPath" -ForegroundColor Green

    return $inventory
}


function Invoke-SatisfactionVerification {
    <#
    .SYNOPSIS
        Verifies each requirement against actual code to determine accurate satisfaction status.
        If deep verify is enabled, reads source code to check for real implementations vs stubs.
    .PARAMETER GsdDir
        Path to the .gsd directory.
    .PARAMETER RepoRoot
        Repository root path.
    .PARAMETER Config
        Global config object.
    .PARAMETER Inventory
        Code inventory from Invoke-CodeInventory.
    .RETURNS
        Health percentage (0-100).
    #>
    param(
        [Parameter(Mandatory)][string]$GsdDir,
        [Parameter(Mandatory)][string]$RepoRoot,
        [PSObject]$Config,
        [PSObject]$Inventory
    )

    $ecmConfig = $Config.existing_codebase_mode
    $deepVerify = if ($ecmConfig.verify_by_reading_code) { $ecmConfig.verify_by_reading_code } else { $false }
    $stubPatterns = if ($ecmConfig.stub_detection_patterns) {
        @($ecmConfig.stub_detection_patterns)
    } else {
        @("// TODO", "// FILL", "throw NotImplementedException", "throw new NotImplementedException")
    }

    Write-Host "`n--- Satisfaction Verification (Existing Codebase Mode) ---" -ForegroundColor Yellow

    $matrixPath = Join-Path $GsdDir "requirements/requirements-matrix.json"
    if (-not (Test-Path $matrixPath)) {
        Write-Host "  [ERROR] No requirements matrix found at $matrixPath" -ForegroundColor Red
        return 0
    }

    $matrix = Get-Content $matrixPath -Raw | ConvertFrom-Json
    $reqs = $matrix.requirements
    $total = $reqs.Count
    $satisfied = 0
    $partial = 0
    $notStarted = 0

    # Build a lookup of inventory files for fast matching
    $fileIndex = @{}
    if ($Inventory -and $Inventory.files) {
        foreach ($f in $Inventory.files) {
            $fileIndex[$f.path] = $f
        }
    }

    for ($i = 0; $i -lt $reqs.Count; $i++) {
        $req = $reqs[$i]
        $reqId = if ($req.id) { $req.id } else { $req.req_id }
        $expectedFiles = @()
        if ($req.expected_files) { $expectedFiles = @($req.expected_files) }
        if ($req.files) { $expectedFiles += @($req.files) }

        if ($expectedFiles.Count -eq 0) {
            # No file mapping -- leave status unchanged
            continue
        }

        $filesExist = 0
        $filesWithStubs = 0
        $totalExpected = $expectedFiles.Count

        foreach ($filePath in $expectedFiles) {
            $normalizedPath = $filePath.Replace("\", "/")
            $fullPath = Join-Path $RepoRoot $normalizedPath

            if (Test-Path $fullPath) {
                $filesExist++

                if ($deepVerify) {
                    # Read file and check for stubs
                    try {
                        $content = Get-Content $fullPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                        if ($content) {
                            $hasStub = $false
                            foreach ($pattern in $stubPatterns) {
                                if ($content -match [regex]::Escape($pattern)) {
                                    $hasStub = $true
                                    break
                                }
                            }
                            if ($hasStub) {
                                $filesWithStubs++
                            }
                        }
                    } catch {}
                }
            }
        }

        # Determine status
        $oldStatus = $req.status
        if ($filesExist -eq 0) {
            $req.status = "not_started"
            $notStarted++
        } elseif ($deepVerify -and $filesWithStubs -gt 0) {
            $req.status = "partial"
            $partial++
        } elseif ($filesExist -lt $totalExpected) {
            $req.status = "partial"
            $partial++
        } else {
            $req.status = "satisfied"
            $satisfied++
        }

        if ($oldStatus -ne $req.status) {
            Write-Host "    [$reqId] $oldStatus -> $($req.status) ($filesExist/$totalExpected files, $filesWithStubs stubs)" -ForegroundColor DarkGray
        }

        $reqs[$i] = $req
    }

    # Save updated matrix
    $matrix.requirements = $reqs
    $matrix | ConvertTo-Json -Depth 10 | Set-Content $matrixPath -Encoding UTF8

    $healthPct = if ($total -gt 0) { [math]::Round(($satisfied / $total) * 100, 1) } else { 0 }

    Write-Host "  [RESULTS] Total: $total | Satisfied: $satisfied | Partial: $partial | Not Started: $notStarted" -ForegroundColor Cyan
    Write-Host "  [HEALTH] $healthPct%" -ForegroundColor $(if ($healthPct -ge 80) { "Green" } elseif ($healthPct -ge 50) { "Yellow" } else { "Red" })

    return $healthPct
}
