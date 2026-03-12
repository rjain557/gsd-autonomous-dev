<#
.SYNOPSIS
    GSD V3 Phase Orchestrator - 10-phase convergence loop, mode-aware, checkpoint/recovery
.DESCRIPTION
    The main convergence loop. Routes phases to the correct model (Sonnet or Codex Mini),
    manages iteration flow, speculative execution, and convergence detection.
    Fixes V2 issues:
    - V2 used CLI tools (claude, codex) via process spawning — fragile, no structured output
    - V2 had separate convergence-loop.ps1 and pipeline.ps1 with duplicated logic
    - V2 did not enforce JSON output, causing parse failures
    - V2 had no local validation phase (went straight from execute to review)
    - V2 had no speculative execution (idle time between review and next iteration)
    - V2 had no budget enforcement (could run indefinitely)
    - V2 had no cache management
#>

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

    # -- File inventory (FIRST THING — everything depends on this) --
    Write-Host "`n--- File Inventory ---" -ForegroundColor Yellow
    $inventory = Build-FileInventory -RepoRoot $RepoRoot -GsdDir $GsdDir

    # -- Lock --
    New-GsdLock -GsdDir $GsdDir -Pipeline "v3" -Mode $Mode

    # -- Build spec context for cache prefix --
    Write-Host "`n--- Building Cache Prefix ---" -ForegroundColor Yellow
    $specContext = Build-SpecContext -RepoRoot $RepoRoot -GsdDir $GsdDir -Inventory $inventory
    $blueprintContext = Build-BlueprintContext -RepoRoot $RepoRoot -GsdDir $GsdDir -Inventory $inventory

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

    # -- Iteration Loop --
    $prevHealth = 0
    $currentHealth = 0
    $converged = $false

    for ($iter = $StartIteration; $iter -le $maxIterations; $iter++) {
        Write-Host "`n========================================" -ForegroundColor Cyan
        Write-Host "  ITERATION $iter / $maxIterations" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan

        try {  # Crash protection: one bad iteration should not kill the pipeline

        # Budget check — estimate cost of upcoming iteration before starting
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

        $batchReqs = $scopedReqs | Select-Object -First $batchSizeMax
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
                $parentsDecomposed += $parentId

                $parentReq = $reqs | Where-Object { ($_.id -eq $parentId) -or ($_.req_id -eq $parentId) }
                if ($parentReq) {
                    $parentReq.status = "satisfied"
                    $parentReq | Add-Member -NotePropertyName "decomposed" -NotePropertyValue $true -Force
                    $parentReq | Add-Member -NotePropertyName "notes" -NotePropertyValue "Research-decomposed into $($decomp.sub_requirements.Count) sub-reqs: $($decomp.reason)" -Force
                }

                foreach ($sub in $decomp.sub_requirements) {
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
                }
            }

            if ($totalAdded -gt 0) {
                $matrix.requirements = $reqs.ToArray()
                $matrix.total = $reqs.Count
                $matrix.summary.satisfied = @($reqs | Where-Object { $_.status -eq "satisfied" }).Count
                $matrix.summary.partial = @($reqs | Where-Object { $_.status -eq "partial" }).Count
                $matrix.summary.not_started = @($reqs | Where-Object { $_.status -eq "not_started" }).Count
                $matrix | ConvertTo-Json -Depth 10 | Set-Content $matrixPath -Encoding UTF8

                Write-Host "  [RESEARCH-DECOMPOSE] Split $($parentsDecomposed.Count) large reqs into $totalAdded sub-reqs" -ForegroundColor Cyan
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
                        Write-Host "  [WARN] $rid flagged needs_decomposition but Research didn't split it — ENFORCE-DECOMPOSE will catch it post-Plan" -ForegroundColor DarkYellow
                    }
                }
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
                $parentsDecomposed += $parentId

                # Mark parent as decomposed (not executed directly)
                $parentReq = $reqs | Where-Object { ($_.id -eq $parentId) -or ($_.req_id -eq $parentId) }
                if ($parentReq) {
                    $parentReq.status = "satisfied"
                    $parentReq | Add-Member -NotePropertyName "decomposed" -NotePropertyValue $true -Force
                    $parentReq | Add-Member -NotePropertyName "notes" -NotePropertyValue "Decomposed into $($decomp.sub_requirements.Count) sub-requirements" -Force
                }

                # Add sub-requirements to matrix
                foreach ($sub in $decomp.sub_requirements) {
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

                # Remove plans for decomposed parents — they'll be picked up as sub-reqs next iteration
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
            $rid = if ($plan.req_id) { $plan.req_id } else { $plan.id }

            if ($fileCount -ge 3 -or $estTokens -gt 8000) {
                Write-Host "  [ENFORCE-DECOMPOSE] $rid has $fileCount files, ~$estTokens tokens — too large for single Codex call" -ForegroundColor Yellow
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
                        Write-Host "    [SUB] $subId — $layer ($($groups[$layer].Count) files)" -ForegroundColor DarkCyan
                    }
                    $subIdx++
                }

                # Mark parent as decomposed
                if ($parentReq) {
                    $parentReq.status = "satisfied"
                    $parentReq | Add-Member -NotePropertyName "decomposed" -NotePropertyValue $true -Force
                    $parentReq | Add-Member -NotePropertyName "notes" -NotePropertyValue "Auto-decomposed into $($subIdx-1) sub-requirements (>5 files or >10K tokens)" -Force
                }
            }

            if ($totalAdded -gt 0) {
                $matrix.requirements = $reqs.ToArray()
                $matrix.total = $reqs.Count
                $matrix.summary.satisfied = @($reqs | Where-Object { $_.status -eq "satisfied" }).Count
                $matrix.summary.partial = @($reqs | Where-Object { $_.status -eq "partial" }).Count
                $matrix.summary.not_started = @($reqs | Where-Object { $_.status -eq "not_started" }).Count
                $matrix | ConvertTo-Json -Depth 10 | Set-Content $matrixPath -Encoding UTF8
                Write-Host "  [ENFORCE-DECOMPOSE] Auto-split $($plansToDecompose.Count) reqs into $totalAdded sub-reqs" -ForegroundColor Cyan
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
                # Skip fill — go to local validate
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
            # Also decrement (reward) items that passed — they should stay prioritized
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
                Write-Host "  [DEPRIORITIZE] $($highFailReqs.Count) reqs failed 3+ times — moved to back of queue" -ForegroundColor DarkYellow
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

        # Cost summary
        Save-CostSummary -GsdDir $GsdDir
        Write-Host "  $(Get-CostSummaryText)" -ForegroundColor DarkGray

        # Convergence check
        if ($currentHealth -ge $Config.target_health) {
            Write-Host "`n  CONVERGED! Health $currentHealth% >= target $($Config.target_health)%" -ForegroundColor Green
            $converged = $true
            break
        }

        # Stall check
        $stall = Test-StallDetected -GsdDir $GsdDir -StallThreshold $Config.stall_threshold
        if ($stall.Stalled) {
            Write-Host "  [STALL] $($stall.Reason)" -ForegroundColor Red
            Send-GsdNotification -Title "GSD Stalled" -Message $stall.Reason -Tags "warning"

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

        # Git commit iteration
        try {
            $commitFiles = Get-ChildItem -Path $RepoRoot -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notlike "*node_modules*" -and $_.FullName -notlike "*.gsd*" } |
                Select-Object -First 1
            if ($commitFiles) {
                git -C $RepoRoot add -A 2>&1 | Out-Null
                git -C $RepoRoot commit -m "GSD v3: Iteration $iter - health $currentHealth%" --allow-empty 2>&1 | Out-Null
            }
        } catch {}

        $prevHealth = $currentHealth

        # Notification
        Send-GsdNotification -Title "GSD Iteration $iter Complete" `
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

    if ($converged) {
        Clear-Checkpoint -GsdDir $GsdDir
        Send-GsdNotification -Title "GSD CONVERGED!" `
            -Message "Health: 100% | Cost: `$$([math]::Round($script:CostState.TotalUsd, 2)) | Mode: $Mode" `
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

    # Include requirements matrix SUMMARY (not full content — matrix can be 200K+ tokens)
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

    $result = Invoke-SonnetApi -CacheBlocks $CacheBlocks -UserMessage $prompt `
        -MaxTokens 4096 -UseCache -JsonMode -Phase "spec-gate"

    if ($result.Usage) { Add-ApiCallCost -Model $script:SonnetModel -Usage $result.Usage -Phase "spec-gate" }

    $blocked = $false
    if ($result.Parsed) {
        $report = $result.Parsed
        $blocked = ($report.overall_status -eq "block")

        $reportPath = Join-Path $GsdDir "specs/spec-quality-report.json"
        $result.Text | Set-Content $reportPath -Encoding UTF8

        Write-Host "  Status: $($report.overall_status) | Clarity: $($report.clarity_score)" -ForegroundColor $(
            if ($report.overall_status -eq "block") { "Red" }
            elseif ($report.overall_status -eq "warn") { "Yellow" }
            else { "Green" }
        )
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
        $researchJson = $Research | ConvertTo-Json -Depth 5 -Compress
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

    # Build parallel items
    $items = @()
    foreach ($plan in $Plans) {
        $prompt = $promptTemplate.Replace("{{REQ_ID}}", $plan.req_id)
        $prompt = $prompt.Replace("{{PLAN}}", ($plan | ConvertTo-Json -Depth 10))

        if ($SkeletonResults -and $SkeletonResults.Results -and $SkeletonResults.Results[$plan.req_id]) {
            $prompt = $prompt.Replace("{{SKELETON}}", $SkeletonResults.Results[$plan.req_id].Text)
        }

        # Inject interface-specific conventions
        $interface = if ($plan.interface) { $plan.interface } else { "web" }
        $ifaceConventions = Get-InterfaceConventions -Interface $interface -Config $Config
        $systemPrompt = "$conventions`n`n## Interface: $interface`n$ifaceConventions"

        $items += @{
            Id           = $plan.req_id
            SystemPrompt = $systemPrompt
            UserMessage  = $prompt
            Model        = $null  # Use default Codex Mini
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

    # Read current health and matrix — TRUNCATED to prevent token explosion
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
            $matrixContent = $slimMatrix | ConvertTo-Json -Depth 10 -Compress
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

    # Apply verify results to requirements matrix (THIS WAS MISSING — root cause of health stall)
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
            foreach ($req in $matrixRaw.requirements) {
                if ($statusMap.ContainsKey($req.id)) {
                    $oldStatus = $req.status
                    $newStatus = $statusMap[$req.id]
                    if ($oldStatus -ne $newStatus) {
                        $req.status = $newStatus
                        $updated++
                    }
                }
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

        # ReviewResults is parsed JSON from Sonnet — structure varies but typically has reviews array
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
            $reviewJson = $ReviewResults | ConvertTo-Json -Depth 3 -Compress
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
        # Single file output — save as raw
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
        # SMART WRITE GUARD — 3-layer defense against disease
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
            continue
        }

        # Layer 2: Protected interfaces — NEVER overwrite (contract stability)
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
            "src/Server/Technijian.Api/Compliance/ComplianceOptions.cs"
        )
        if ($filePath -in $protectedInterfaces -and (Test-Path $fullPath)) {
            Write-Host "      [PROTECTED] $filePath -- tracked interface/base class, skipping overwrite" -ForegroundColor Cyan
            continue
        }

        # Layer 3: Smart implementation guard — only write if compatible with existing interfaces
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

            # Guard 3b: Block writes that shrink real files by >50% (likely truncated/incomplete output)
            if (-not $newHasFill -and -not $existingHasFill -and $existingSize -gt 500) {
                $shrinkRatio = if ($existingSize -gt 0) { $content.Length / $existingSize } else { 1 }
                if ($shrinkRatio -lt 0.5) {
                    Write-Host "      [BLOCKED] $filePath -- new content is $([math]::Round((1-$shrinkRatio)*100))% smaller ($existingSize -> $($content.Length) chars), likely truncated" -ForegroundColor Red
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
