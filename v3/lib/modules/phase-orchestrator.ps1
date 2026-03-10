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
    $script:SonnetModel = "claude-sonnet-4-6-20260310"

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

        # Budget check
        if (-not (Test-BudgetAvailable)) {
            Write-Host "  [BUDGET] Budget exhausted. Halting." -ForegroundColor Red
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
            Write-Host "`n  --- Research ---" -ForegroundColor Yellow
            $researchOutput = Invoke-ResearchPhase -GsdDir $GsdDir -RepoRoot $RepoRoot `
                -CacheBlocks $cacheBlocks -Requirements $batchReqs -Iteration $iter `
                -Config $Config -Inventory $inventory
        }

        # -- Plan Phase --
        Write-Host "`n  --- Plan ---" -ForegroundColor Yellow
        $planOutput = Invoke-PlanPhase -GsdDir $GsdDir -RepoRoot $RepoRoot `
            -CacheBlocks $cacheBlocks -Requirements $batchReqs -Iteration $iter `
            -Research $researchOutput -Config $Config -Mode $Mode -Inventory $inventory

        if (-not $planOutput -or -not $planOutput.Plans) {
            Write-Host "  [WARN] Plan phase produced no output, skipping iteration" -ForegroundColor DarkYellow
            continue
        }

        # -- Execute Phase (Two-Stage: Skeleton then Fill) --
        $executeResults = @{}
        $skeletonResults = $null
        $usesTwoStage = $modeConfig.two_stage_execute

        if ($usesTwoStage -and "execute-skeleton" -in $phasesActive -and "execute-skeleton" -notin $phasesSkipped) {
            Write-Host "`n  --- Execute: Skeleton ---" -ForegroundColor Yellow
            $skeletonResults = Invoke-ExecutePhase -GsdDir $GsdDir -RepoRoot $RepoRoot `
                -Plans $planOutput.Plans -Stage "skeleton" -Config $Config -Inventory $inventory
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

        # -- Local Validate Phase (FREE) --
        Write-Host "`n  --- Local Validate ---" -ForegroundColor Yellow
        $validateResults = Invoke-LocalValidatePhase -GsdDir $GsdDir -RepoRoot $RepoRoot `
            -ExecuteResults $executeResults -Plans $planOutput.Plans

        # -- Review Phase (only for failed items) --
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
            -Mode $Mode -BaselineSnapshot $baselineSnapshot

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
    }

    # -- Cleanup --
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

    # Include requirements matrix if it exists
    $matrixPath = Join-Path $GsdDir "requirements/requirements-matrix.json"
    if (Test-Path $matrixPath) {
        $matrixContent = Get-Content $matrixPath -Raw -Encoding UTF8
        $context += "## Requirements Matrix`n`n``````json`n$matrixContent`n```````n`n"
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
        if ($tree.Length -gt 5000) { $tree = $tree.Substring(0, 5000) + "`n... (truncated)" }
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

    if ($result.Usage) { Add-ApiCallCost -Model $script:SonnetModel -Usage $result.Usage -Phase "spec-gate" -IsBatch }

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

    $reqSummary = ($Requirements | ForEach-Object { "- $($_.req_id): $($_.description)" }) -join "`n"
    $prompt = $promptTemplate.Replace("{{ITERATION}}", "$Iteration")
    $prompt = $prompt.Replace("{{REQUIREMENTS}}", $reqSummary)
    $prompt = $prompt.Replace("{{FILE_INVENTORY}}", ($Inventory.all_files | Select-Object -First 200) -join "`n")

    $result = Invoke-SonnetApi -CacheBlocks $CacheBlocks -UserMessage $prompt `
        -MaxTokens 6000 -UseCache -JsonMode -Phase "research"

    if ($result.Usage) { Add-ApiCallCost -Model $script:SonnetModel -Usage $result.Usage -Phase "research" -IsBatch }

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

    $reqSummary = ($Requirements | ForEach-Object { "- $($_.req_id): $($_.description) [interface: $($_.interface)]" }) -join "`n"
    $researchSummary = if ($Research) { $Research | ConvertTo-Json -Depth 5 -Compress } else { "(no research)" }

    $prompt = $promptTemplate.Replace("{{ITERATION}}", "$Iteration")
    $prompt = $prompt.Replace("{{REQUIREMENTS}}", $reqSummary)
    $prompt = $prompt.Replace("{{RESEARCH}}", $researchSummary)
    $prompt = $prompt.Replace("{{FILE_INVENTORY}}", ($Inventory.source_files | Select-Object -First 100) -join "`n")

    $result = Invoke-SonnetApi -CacheBlocks $CacheBlocks -UserMessage $prompt `
        -MaxTokens 8000 -UseCache -JsonMode -Phase "plan"

    if ($result.Usage) { Add-ApiCallCost -Model $script:SonnetModel -Usage $result.Usage -Phase "plan" -IsBatch }

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

    $results = Invoke-CodexMiniParallel -Items $items -MaxConcurrent 15 -Phase "execute-$Stage"

    # Write generated files to disk
    foreach ($reqId in $results.Results.Keys) {
        $r = $results.Results[$reqId]
        if ($r.Success -and $r.Text) {
            Write-GeneratedFiles -RepoRoot $RepoRoot -GsdDir $GsdDir -ReqId $reqId -Output $r.Text
        }
        if ($r.Usage) {
            Add-ApiCallCost -Model "gpt-5.1-codex-mini" -Usage $r.Usage -Phase "execute-$Stage" -RequirementId $reqId
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
    if ($gitDiff.Length -gt 12000) { $gitDiff = $gitDiff.Substring(0, 12000) + "`n... (truncated)" }

    $prompt = $promptTemplate.Replace("{{ITERATION}}", "$Iteration")
    $prompt = $prompt.Replace("{{ERROR_CONTEXT}}", $errorContext)
    $prompt = $prompt.Replace("{{GIT_DIFF}}", $gitDiff)

    $result = Invoke-SonnetApi -CacheBlocks $CacheBlocks -UserMessage $prompt `
        -MaxTokens 4000 -UseCache -JsonMode -Phase "review"

    if ($result.Usage) { Add-ApiCallCost -Model $script:SonnetModel -Usage $result.Usage -Phase "review" -IsBatch }

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
        [hashtable]$BaselineSnapshot = @{}
    )

    $promptPath = Join-Path $script:V3Root "prompts/sonnet/07-verify.md"
    $promptTemplate = if (Test-Path $promptPath) { Get-Content $promptPath -Raw -Encoding UTF8 } else {
        "Update requirement statuses. Calculate health score. Detect drift. Output JSON."
    }

    # Read current health and matrix
    $matrixPath = Join-Path $GsdDir "requirements/requirements-matrix.json"
    $matrixContent = if (Test-Path $matrixPath) { Get-Content $matrixPath -Raw -Encoding UTF8 } else { "{}" }

    $prompt = $promptTemplate.Replace("{{ITERATION}}", "$Iteration")
    $prompt = $prompt.Replace("{{REQUIREMENTS_MATRIX}}", $matrixContent)
    $prompt = $prompt.Replace("{{MODE}}", $Mode)

    $result = Invoke-SonnetApi -CacheBlocks $CacheBlocks -UserMessage $prompt `
        -MaxTokens 3000 -UseCache -JsonMode -Phase "verify"

    if ($result.Usage) { Add-ApiCallCost -Model $script:SonnetModel -Usage $result.Usage -Phase "verify" }

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

    if ($result.Usage) { Add-ApiCallCost -Model $script:SonnetModel -Usage $result.Usage -Phase "spec-fix" -IsBatch }

    # Invalidate cache after spec fix
    if ($result.Parsed -and $result.Parsed.cache_invalidation) {
        Write-Host "  [CACHE] Spec fix invalidated cache block 2" -ForegroundColor Yellow
    }
}

# ============================================================
# HELPERS
# ============================================================

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

    for ($i = 0; $i -lt $fileMatches.Count; $i++) {
        $filePath = $fileMatches[$i].Groups[1].Value.Trim()
        $startIdx = $fileMatches[$i].Index + $fileMatches[$i].Length

        $endIdx = if ($i + 1 -lt $fileMatches.Count) { $fileMatches[$i + 1].Index } else { $Output.Length }
        $content = $Output.Substring($startIdx, $endIdx - $startIdx).Trim()

        # Strip code fences if present
        if ($content -match '^```\w*\n([\s\S]*?)\n```$') { $content = $Matches[1] }

        $fullPath = Join-Path $RepoRoot $filePath
        $dir = Split-Path $fullPath -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

        Set-Content $fullPath -Value $content -Encoding UTF8
        Write-Host "      [WRITE] $filePath" -ForegroundColor DarkGray
    }
}
