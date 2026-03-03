<#
.SYNOPSIS
    Parallel Sub-Task Execution - Splits execute batch into independent sub-tasks dispatched in parallel.
    Fixes GAP: Large batches (6+ tasks, 100K+ tokens) cause quota exhaustion, partial results, or timeouts.

.DESCRIPTION
    Adds parallel sub-task execution to the GSD engine:
    1. Adds execute_parallel config to agent-map.json
    2. Creates execute-subtask.md prompt template for single sub-tasks
    3. Adds Invoke-ParallelExecute function to resilience.ps1
    4. Updates convergence-loop.ps1 to use parallel dispatch when enabled

    The batch is split into independent sub-tasks, each dispatched to an agent (round-robin across
    codex/claude/gemini). Failed sub-tasks retry independently. Partial success commits completed work.
    Falls back to monolithic single-agent call when parallel is disabled or all sub-tasks fail.

.USAGE
    powershell -ExecutionPolicy Bypass -File patch-gsd-parallel-execute.ps1

.INSTALL_ORDER
    1. install-gsd-global.ps1        (creates base engine)
    2. patch-gsd-resilience.ps1      (creates resilience.ps1)
    3. patch-gsd-hardening.ps1       (appends hardening functions)
    4. patch-gsd-final-validation.ps1 (appends validation gate)
    5. final-patch-5-convergence-pipeline.ps1 (final convergence loop)
    6. patch-gsd-parallel-execute.ps1 <- this file
#>

param([string]$UserHome = $env:USERPROFILE)
$ErrorActionPreference = "Stop"

$GsdGlobalDir = Join-Path $UserHome ".gsd-global"

Write-Host ""
Write-Host "  [PARALLEL] Installing Parallel Sub-Task Execution..." -ForegroundColor Cyan
Write-Host ""

# ── 1. Add execute_parallel config to agent-map.json ──

$agentMapPath = Join-Path $GsdGlobalDir "config\agent-map.json"
if (Test-Path $agentMapPath) {
    $agentMap = Get-Content $agentMapPath -Raw | ConvertFrom-Json

    if (-not $agentMap.execute_parallel) {
        # Add parallel config
        $agentMap | Add-Member -NotePropertyName "execute_parallel" -NotePropertyValue ([PSCustomObject]@{
            enabled                 = $true
            max_concurrent          = 3
            agent_pool              = @("codex", "claude", "gemini")
            strategy                = "round-robin"
            fallback_to_sequential  = $true
            subtask_timeout_minutes = 30
        })

        $agentMap | ConvertTo-Json -Depth 10 | Set-Content -Path $agentMapPath -Encoding UTF8
        Write-Host "  [OK] Added execute_parallel config to agent-map.json" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] execute_parallel already exists in agent-map.json" -ForegroundColor DarkGray
    }
} else {
    Write-Host "  [WARN] agent-map.json not found at $agentMapPath" -ForegroundColor Yellow
}

# ── 2. Create execute-subtask.md prompt template ──

$subtaskPromptDir = Join-Path $GsdGlobalDir "prompts\codex"
$subtaskPromptPath = Join-Path $subtaskPromptDir "execute-subtask.md"

if (-not (Test-Path $subtaskPromptDir)) {
    New-Item -Path $subtaskPromptDir -ItemType Directory -Force | Out-Null
}

$subtaskPrompt = @'
# GSD Execute - Sub-Task {{SUBTASK_INDEX}} of {{SUBTASK_TOTAL}}

You are the DEVELOPER. Generate ALL code needed for this ONE sub-task.

## Context
- Iteration: {{ITERATION}}
- Health: {{HEALTH}}%
- Project .gsd dir: {{GSD_DIR}}
- Sub-task: {{SUBTASK_REQ_ID}} ({{SUBTASK_INDEX}}/{{SUBTASK_TOTAL}})

## Your Assignment

**Requirement:** {{SUBTASK_REQ_ID}}
**Description:** {{SUBTASK_DESCRIPTION}}
**Target Files:** {{SUBTASK_TARGET_FILES}}

### Instructions
{{SUBTASK_INSTRUCTIONS}}

### Acceptance Criteria
{{SUBTASK_ACCEPTANCE}}

## Read (for context only)
1. {{GSD_DIR}}\agent-handoff\current-assignment.md - find YOUR task section
2. {{GSD_DIR}}\health\requirements-matrix.json - full requirements context
3. {{GSD_DIR}}\research\ - research findings

## Project Patterns (STRICT)

### Backend (.NET 8)
- Dapper for ALL data access (never Entity Framework)
- SQL Server stored procedures ONLY (never inline SQL)
- Repository pattern wrapping Dapper calls

### Frontend (React 18)
- Functional components with hooks ONLY
- Match Figma designs EXACTLY

### Database (SQL Server)
- ALL data access through stored procedures
- Parameterized queries (never string concatenation)

## Execute
1. Create/modify ONLY the files listed in Target Files
2. Write COMPLETE files (not snippets)
3. Include error handling, logging, input validation

## After Generating
- Append completion entry to {{GSD_DIR}}\agent-handoff\handoff-log.jsonl:
  {"agent":"{{AGENT}}","action":"subtask-complete","iteration":{{ITERATION}},"subtask":"{{SUBTASK_REQ_ID}}","files_created":[...],"files_modified":[...],"timestamp":"..."}

## Boundaries
- DO NOT modify anything in {{GSD_DIR}}\code-review\
- DO NOT modify anything in {{GSD_DIR}}\health\
- DO NOT modify anything in {{GSD_DIR}}\generation-queue\
- DO NOT modify files outside your Target Files list
- WRITE source code + handoff log entries ONLY
'@

Set-Content -Path $subtaskPromptPath -Value $subtaskPrompt -Encoding UTF8
Write-Host "  [OK] Created execute-subtask.md prompt template" -ForegroundColor Green

# ── 3. Add Invoke-ParallelExecute function to resilience.ps1 ──

$resilienceFile = Join-Path $GsdGlobalDir "lib\modules\resilience.ps1"
if (Test-Path $resilienceFile) {
    $existing = Get-Content $resilienceFile -Raw

    if ($existing -notlike "*function Invoke-ParallelExecute*") {

        $parallelFunction = @'

# ===========================================
# 8b. PARALLEL SUB-TASK EXECUTION
# ===========================================

function Invoke-ParallelExecute {
    param(
        [string]$GsdDir,                    # .gsd directory path
        [string]$GlobalDir,                 # .gsd-global directory path
        [int]$Iteration,                    # Current iteration number
        [decimal]$Health,                   # Current health score
        [string]$PromptTemplatePath,        # Path to execute-subtask.md
        [int]$CurrentBatchSize,             # Current batch size (for result)
        [string]$LogFilePrefix,             # e.g., "$GsdDir\logs\iter3-4"
        [string]$InterfaceContext = "",     # Multi-interface context string
        [switch]$DryRun
    )

    $result = @{
        Success        = $false
        PartialSuccess = $false
        FinalBatchSize = $CurrentBatchSize
        Completed      = @()
        Failed         = @()
        Error          = ""
    }

    # ── 1. Load parallel config ──
    $agentMapPath = Join-Path $GlobalDir "config\agent-map.json"
    $agentMap = Get-Content $agentMapPath -Raw | ConvertFrom-Json
    $parallelCfg = $agentMap.execute_parallel

    if (-not $parallelCfg -or -not $parallelCfg.enabled) {
        $result.Error = "Parallel execution not enabled in agent-map.json"
        return $result
    }

    $maxConcurrent  = [int]$parallelCfg.max_concurrent
    $agentPool      = @($parallelCfg.agent_pool)
    $strategy       = $parallelCfg.strategy        # "round-robin" or "all-same"
    $subtaskTimeout = [int]$parallelCfg.subtask_timeout_minutes

    # ── 2. Load queue and decompose into sub-tasks ──
    $queuePath = Join-Path $GsdDir "generation-queue\queue-current.json"
    $queue = Get-Content $queuePath -Raw | ConvertFrom-Json
    $batch = @($queue.batch)

    if ($batch.Count -eq 0) {
        $result.Error = "No batch items in queue-current.json"
        return $result
    }

    Write-Host "  [PARALLEL] Decomposing batch: $($batch.Count) sub-tasks" -ForegroundColor Cyan

    # ── 3. Build per-subtask prompts ──
    $templateText = Get-Content $PromptTemplatePath -Raw
    $subtasks = @()

    for ($idx = 0; $idx -lt $batch.Count; $idx++) {
        $item = $batch[$idx]

        # Select agent: round-robin across pool
        if ($strategy -eq "round-robin") {
            $agent = $agentPool[$idx % $agentPool.Count]
        } else {
            $agent = $agentPool[0]
        }

        # Check agent override
        $overridePath = Join-Path $GsdDir "supervisor\agent-override.json"
        if (Test-Path $overridePath) {
            try {
                $ov = Get-Content $overridePath -Raw | ConvertFrom-Json
                if ($ov.execute) { $agent = $ov.execute }
            } catch {}
        }

        # Resolve prompt template with sub-task placeholders
        $prompt = $templateText
        $prompt = $prompt.Replace("{{ITERATION}}", "$Iteration")
        $prompt = $prompt.Replace("{{HEALTH}}", "$Health")
        $prompt = $prompt.Replace("{{GSD_DIR}}", $GsdDir)
        $prompt = $prompt.Replace("{{SUBTASK_INDEX}}", "$($idx + 1)")
        $prompt = $prompt.Replace("{{SUBTASK_TOTAL}}", "$($batch.Count)")
        $prompt = $prompt.Replace("{{SUBTASK_REQ_ID}}", $item.req_id)
        $prompt = $prompt.Replace("{{SUBTASK_DESCRIPTION}}", $item.description)
        $prompt = $prompt.Replace("{{SUBTASK_TARGET_FILES}}", ($item.target_files -join ", "))
        $prompt = $prompt.Replace("{{SUBTASK_INSTRUCTIONS}}", $item.generation_instructions)
        $prompt = $prompt.Replace("{{SUBTASK_ACCEPTANCE}}", $item.acceptance)
        $prompt = $prompt.Replace("{{AGENT}}", $agent)
        $prompt = $prompt.Replace("{{BATCH_SIZE}}", "1")
        $prompt = $prompt.Replace("{{REPO_ROOT}}", (Get-Location).Path)
        $prompt = $prompt.Replace("{{INTERFACE_CONTEXT}}", $InterfaceContext)
        $prompt = $prompt.Replace("{{FIGMA_PATH}}", "(see interface context)")
        $prompt = $prompt.Replace("{{FIGMA_VERSION}}", "(multi-interface)")

        $subtasks += @{
            Index   = $idx
            ReqId   = $item.req_id
            Agent   = $agent
            Prompt  = $prompt
            LogFile = "${LogFilePrefix}-sub${idx}.log"
        }
    }

    # ── 4. Dispatch sub-tasks ──
    Write-Host "  [PARALLEL] Dispatching $($subtasks.Count) sub-tasks (max concurrent: $maxConcurrent)" -ForegroundColor Cyan
    foreach ($st in $subtasks) {
        Write-Host "    [$($st.Index + 1)] $($st.ReqId) -> $($st.Agent)" -ForegroundColor DarkCyan
    }

    if ($DryRun) {
        Write-Host "  [DRY-RUN] Would dispatch $($subtasks.Count) sub-tasks" -ForegroundColor Yellow
        $result.Success = $true
        $result.Completed = $subtasks | ForEach-Object { $_.ReqId }
        return $result
    }

    # ── 5. Execute in batches of $maxConcurrent using PowerShell jobs ──
    $completedReqs = @()
    $failedReqs    = @()

    for ($batchStart = 0; $batchStart -lt $subtasks.Count; $batchStart += $maxConcurrent) {
        $batchEnd = [math]::Min($batchStart + $maxConcurrent, $subtasks.Count) - 1
        $currentBatch = $subtasks[$batchStart..$batchEnd]

        Write-Host "  [PARALLEL] Wave $([math]::Floor($batchStart / $maxConcurrent) + 1): sub-tasks $($batchStart + 1)..$($batchEnd + 1)" -ForegroundColor Cyan

        if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
            Update-EngineStatus -GsdDir $GsdDir -State "running" -Phase "execute" `
                -Agent "parallel($($currentBatch.Count))" `
                -Iteration $Iteration -HealthScore $Health
        }

        $jobs = @()
        foreach ($st in $currentBatch) {
            $jobName = "gsd-subtask-$($st.ReqId)"
            $stAgent   = $st.Agent
            $stPrompt  = $st.Prompt
            $stLogFile = $st.LogFile
            $stReqId   = $st.ReqId

            # Start-Job runs in a separate process — pass all needed vars
            $job = Start-Job -Name $jobName -ScriptBlock {
                param($Agent, $Prompt, $LogFile, $ReqId, $GlobalDir, $GsdDir, $SubtaskTimeout)

                # Load resilience module inside the job
                . "$GlobalDir\lib\modules\resilience.ps1"

                # Determine AllowedTools and GeminiMode based on agent
                $allowedTools = "Read,Write,Bash,mcp__*"
                $geminiMode   = "--yolo"

                $subResult = Invoke-WithRetry -Agent $Agent -Prompt $Prompt `
                    -Phase "execute" -LogFile $LogFile `
                    -CurrentBatchSize 1 -GsdDir $GsdDir `
                    -AllowedTools $allowedTools -GeminiMode $geminiMode `
                    -MaxAttempts 2

                return @{
                    ReqId   = $ReqId
                    Success = $subResult.Success
                    Error   = $subResult.Error
                    Agent   = $Agent
                }
            } -ArgumentList $stAgent, $stPrompt, $stLogFile, $stReqId, $GlobalDir, $GsdDir, $subtaskTimeout

            $jobs += $job
        }

        # Wait for all jobs in this wave with timeout
        $timeoutSec = $subtaskTimeout * 60
        $allDone = $jobs | Wait-Job -Timeout $timeoutSec

        # Collect results
        foreach ($job in $jobs) {
            $jobResult = $null
            if ($job.State -eq "Completed") {
                $jobResult = Receive-Job -Job $job
            }

            if ($jobResult -and $jobResult.Success) {
                $completedReqs += $jobResult.ReqId
                Write-Host "    [OK] $($jobResult.ReqId) ($($jobResult.Agent))" -ForegroundColor Green
            } else {
                $reqId = if ($jobResult) { $jobResult.ReqId } else { "unknown" }
                $err   = if ($jobResult) { $jobResult.Error } else { "Job timed out or crashed" }
                $failedReqs += $reqId
                Write-Host "    [FAIL] $reqId : $err" -ForegroundColor Red

                # Log the failure
                if (Get-Command Write-GsdError -ErrorAction SilentlyContinue) {
                    Write-GsdError -GsdDir $GsdDir -Category "subtask_failed" `
                        -Phase "execute" -Iteration $Iteration -Message "$reqId : $err"
                }
            }

            # Cleanup
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }

        # Throttle between waves (avoid quota spike)
        if ($batchEnd -lt ($subtasks.Count - 1)) {
            Write-Host "  [PARALLEL] Wave complete. 10s cooldown..." -ForegroundColor DarkGray
            Start-Sleep -Seconds 10
        }
    }

    # ── 6. Aggregate results ──
    $result.Completed = $completedReqs
    $result.Failed    = $failedReqs
    $result.FinalBatchSize = $CurrentBatchSize

    if ($failedReqs.Count -eq 0) {
        $result.Success = $true
        Write-Host "  [PARALLEL] All $($completedReqs.Count)/$($subtasks.Count) sub-tasks completed" -ForegroundColor Green
    }
    elseif ($completedReqs.Count -gt 0) {
        $result.PartialSuccess = $true
        $result.Error = "$($failedReqs.Count)/$($subtasks.Count) sub-tasks failed: $($failedReqs -join ', ')"
        Write-Host "  [PARALLEL] Partial: $($completedReqs.Count) OK, $($failedReqs.Count) failed" -ForegroundColor Yellow
    }
    else {
        $result.Error = "All $($subtasks.Count) sub-tasks failed"
        Write-Host "  [PARALLEL] All sub-tasks failed" -ForegroundColor Red
    }

    return $result
}
'@

        # Find insertion point: after Invoke-WithRetry closing brace, before section 9
        $insertBefore = "# ==========================================="
        $sectionMarker = "# 9. ENHANCED BUILD VALIDATION"

        # Find the section 9 marker and insert before it
        $insertIdx = $existing.IndexOf($sectionMarker)
        if ($insertIdx -gt 0) {
            # Find the comment line start (the === line before section 9)
            $searchBack = $existing.LastIndexOf($insertBefore, $insertIdx)
            if ($searchBack -gt 0) {
                $before = $existing.Substring(0, $searchBack)
                $after = $existing.Substring($searchBack)
                $newContent = $before + $parallelFunction + "`n`n" + $after
                Set-Content -Path $resilienceFile -Value $newContent -Encoding UTF8
                Write-Host "  [OK] Added Invoke-ParallelExecute to resilience.ps1" -ForegroundColor Green
            } else {
                # Fallback: append at end
                Add-Content -Path $resilienceFile -Value "`n$parallelFunction" -Encoding UTF8
                Write-Host "  [OK] Appended Invoke-ParallelExecute to resilience.ps1" -ForegroundColor Green
            }
        } else {
            # Fallback: append at end
            Add-Content -Path $resilienceFile -Value "`n$parallelFunction" -Encoding UTF8
            Write-Host "  [OK] Appended Invoke-ParallelExecute to resilience.ps1" -ForegroundColor Green
        }
    } else {
        Write-Host "  [SKIP] Invoke-ParallelExecute already exists in resilience.ps1" -ForegroundColor DarkGray
    }
} else {
    Write-Host "  [WARN] resilience.ps1 not found at $resilienceFile" -ForegroundColor Yellow
}

# ── 4. Update convergence-loop.ps1 with parallel dispatch ──

$convergenceFile = Join-Path $GsdGlobalDir "scripts\convergence-loop.ps1"
if (Test-Path $convergenceFile) {
    $loopContent = Get-Content $convergenceFile -Raw

    if ($loopContent -like "*Invoke-ParallelExecute*") {
        Write-Host "  [SKIP] convergence-loop.ps1 already has parallel dispatch" -ForegroundColor DarkGray
    } else {
        # Find the monolithic execute block and wrap it with parallel-aware dispatch
        $oldExecuteMarker = '# 4. EXECUTE (Codex, or supervisor-overridden agent)'
        $oldExecuteEnd = '# Regression + stall'

        if ($loopContent -like "*$oldExecuteMarker*") {
            $startIdx = $loopContent.IndexOf($oldExecuteMarker)
            $endIdx = $loopContent.IndexOf($oldExecuteEnd)

            if ($startIdx -gt 0 -and $endIdx -gt $startIdx) {
                $before = $loopContent.Substring(0, $startIdx)
                $after = $loopContent.Substring($endIdx)

                $newExecuteBlock = @'
    # 4. EXECUTE — Parallel sub-task or monolithic fallback
    Send-HeartbeatIfDue -Phase "execute" -Iteration $Iteration -Health $Health -RepoName $repoName
    Save-Checkpoint -GsdDir $GsdDir -Pipeline "converge" -Iteration $Iteration -Phase "execute" -Health $Health -BatchSize $CurrentBatchSize

    # Check if parallel execution is enabled
    $useParallel = $false
    $fallback = $false
    $agentMapPath = Join-Path $GlobalDir "config\agent-map.json"
    if (Test-Path $agentMapPath) {
        try {
            $agentMapCfg = Get-Content $agentMapPath -Raw | ConvertFrom-Json
            if ($agentMapCfg.execute_parallel -and $agentMapCfg.execute_parallel.enabled) {
                $useParallel = $true
            }
        } catch {}
    }

    if ($useParallel -and (Get-Command Invoke-ParallelExecute -ErrorAction SilentlyContinue)) {
        # ── PARALLEL PATH ──
        $subtaskTemplate = Join-Path $GlobalDir "prompts\codex\execute-subtask.md"
        if (-not (Test-Path $subtaskTemplate)) {
            Write-Host "  [WARN] execute-subtask.md not found, falling back to monolithic" -ForegroundColor Yellow
            $useParallel = $false
        }
    }

    if ($useParallel -and -not $DryRun) {
        Write-Host "  [WRENCH] PARALLEL EXECUTE (batch: $CurrentBatchSize)" -ForegroundColor Magenta
        if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
            Update-EngineStatus -GsdDir $GsdDir -State "running" -Phase "execute" -Agent "parallel" -Iteration $Iteration -HealthScore $Health -BatchSize $CurrentBatchSize
        }

        $result = Invoke-ParallelExecute -GsdDir $GsdDir -GlobalDir $GlobalDir `
            -Iteration $Iteration -Health $Health `
            -PromptTemplatePath $subtaskTemplate `
            -CurrentBatchSize $CurrentBatchSize `
            -LogFilePrefix "$GsdDir\logs\iter${Iteration}-4" `
            -InterfaceContext $InterfaceContext

        if ($result.Success -or $result.PartialSuccess) {
            $CurrentBatchSize = $result.FinalBatchSize

            # Commit completed work
            $commitSubject = "gsd: iter $Iteration (health: ${Health}%)"
            if ($result.PartialSuccess) {
                $commitSubject += " [partial: $($result.Completed.Count)/$($result.Completed.Count + $result.Failed.Count)]"
            }
            $reviewPath = Join-Path $GsdDir "code-review\review-current.md"
            if (Test-Path $reviewPath) {
                $reviewText = (Get-Content $reviewPath -Raw).Trim()
                if ($reviewText.Length -gt 4000) { $reviewText = $reviewText.Substring(0, 4000) + "`n... (truncated)" }
                $commitMsgFile = Join-Path $GsdDir ".commit-msg.tmp"
                "$commitSubject`n`nCompleted: $($result.Completed -join ', ')`nFailed: $($result.Failed -join ', ')`n`n$reviewText" | Set-Content $commitMsgFile -Encoding UTF8
                git add -A; git commit -F $commitMsgFile --no-verify 2>$null
                Remove-Item $commitMsgFile -ErrorAction SilentlyContinue
            } else {
                git add -A; git commit -m $commitSubject --no-verify 2>$null
            }
            git push 2>$null

            if (Get-Command Update-FileMap -ErrorAction SilentlyContinue) {
                $null = Update-FileMap -Root $RepoRoot -GsdPath $GsdDir
            }
            Invoke-BuildValidation -RepoRoot $RepoRoot -GsdDir $GsdDir -Iteration $Iteration -AutoFix | Out-Null

            # If partial success, log failed sub-tasks for next iteration
            if ($result.PartialSuccess) {
                Write-Host "  [PARTIAL] $($result.Failed.Count) sub-tasks need retry next iteration" -ForegroundColor Yellow
                Send-GsdNotification -Title "Iter ${Iteration}: Partial Execute" `
                    -Message "$repoName | OK: $($result.Completed -join ',') | FAIL: $($result.Failed -join ',')" `
                    -Tags "warning" -Priority "default"
                $script:LAST_NOTIFY_TIME = Get-Date
            }
        } else {
            # All sub-tasks failed — try monolithic fallback if configured
            if ($agentMapCfg.execute_parallel.fallback_to_sequential) {
                Write-Host "  [FALLBACK] All parallel sub-tasks failed. Trying monolithic execute..." -ForegroundColor Yellow
                $fallback = $true
            }

            if (-not $fallback) {
                $CurrentBatchSize = $result.FinalBatchSize; $StallCount++; $errorsThisIter++
                if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
                    Update-EngineStatus -GsdDir $GsdDir -State "running" -ErrorsThisIteration $errorsThisIter -LastError "Parallel execute failed: $($result.Error)"
                }
                Send-GsdNotification -Title "Iter ${Iteration}: Execute Failed" `
                    -Message "$repoName | Health: ${Health}% | All sub-tasks failed" `
                    -Tags "warning" -Priority "default"
                $script:LAST_NOTIFY_TIME = Get-Date
                continue
            }
            # $fallback = $true falls through to monolithic path below
        }
    }

    # ── MONOLITHIC PATH (original behavior, also used as fallback) ──
    if ((-not $useParallel -or $fallback) -and -not $DryRun) {
        $executeAgent = "codex"
        $overridePath = Join-Path $GsdDir "supervisor\agent-override.json"
        if (Test-Path $overridePath) {
            try { $ov = Get-Content $overridePath -Raw | ConvertFrom-Json
                  if ($ov.execute) { $executeAgent = $ov.execute; Write-Host "  [SUPERVISOR] Agent override: execute -> $executeAgent" -ForegroundColor Yellow } } catch {}
        }
        Write-Host "  [WRENCH] $($executeAgent.ToUpper()) -> execute (batch: $CurrentBatchSize)" -ForegroundColor Magenta
        if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
            Update-EngineStatus -GsdDir $GsdDir -State "running" -Phase "execute" -Agent $executeAgent -Iteration $Iteration -HealthScore $Health -BatchSize $CurrentBatchSize
        }
        $prompt = Local-ResolvePrompt "$GlobalDir\prompts\codex\execute.md" $Iteration $Health
        $result = Invoke-WithRetry -Agent $executeAgent -Prompt $prompt -Phase "execute" `
            -LogFile "$GsdDir\logs\iter${Iteration}-4.log" -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir
        if ($result.Success) {
            $CurrentBatchSize = $result.FinalBatchSize
            $reviewPath = Join-Path $GsdDir "code-review\review-current.md"
            $commitSubject = "gsd: iter $Iteration (health: ${Health}%)"
            if (Test-Path $reviewPath) {
                $reviewText = (Get-Content $reviewPath -Raw).Trim()
                if ($reviewText.Length -gt 4000) { $reviewText = $reviewText.Substring(0, 4000) + "`n... (truncated)" }
                $commitMsgFile = Join-Path $GsdDir ".commit-msg.tmp"
                "$commitSubject`n`n$reviewText" | Set-Content $commitMsgFile -Encoding UTF8
                git add -A; git commit -F $commitMsgFile --no-verify 2>$null
                Remove-Item $commitMsgFile -ErrorAction SilentlyContinue
            } else {
                git add -A; git commit -m $commitSubject --no-verify 2>$null
            }
            git push 2>$null
            if (Get-Command Update-FileMap -ErrorAction SilentlyContinue) {
                $null = Update-FileMap -Root $RepoRoot -GsdPath $GsdDir
            }
            Invoke-BuildValidation -RepoRoot $RepoRoot -GsdDir $GsdDir -Iteration $Iteration -AutoFix | Out-Null
        } else {
            $CurrentBatchSize = $result.FinalBatchSize; $StallCount++; $errorsThisIter++
            if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
                Update-EngineStatus -GsdDir $GsdDir -State "running" -ErrorsThisIteration $errorsThisIter -LastError "Execute failed: $($result.Error)"
            }
            Send-GsdNotification -Title "Iter ${Iteration}: Execute Failed" `
                -Message "$repoName | Health: ${Health}% | Batch reduced -> $CurrentBatchSize | Stall $StallCount/$StallThreshold" `
                -Tags "warning" -Priority "default"
            $script:LAST_NOTIFY_TIME = Get-Date
            continue
        }
    }

'@

                $newContent = $before + $newExecuteBlock + "    " + $after
                Set-Content -Path $convergenceFile -Value $newContent -Encoding UTF8
                Write-Host "  [OK] Updated convergence-loop.ps1 with parallel dispatch" -ForegroundColor Green
            } else {
                Write-Host "  [WARN] Could not find execute block boundaries in convergence-loop.ps1" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  [WARN] Could not find monolithic execute marker in convergence-loop.ps1" -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "  [WARN] convergence-loop.ps1 not found at $convergenceFile" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  [PARALLEL] Installation complete." -ForegroundColor Green
Write-Host "  Config: $agentMapPath" -ForegroundColor DarkGray
Write-Host "  Prompt: $subtaskPromptPath" -ForegroundColor DarkGray
Write-Host "  Function: Invoke-ParallelExecute in resilience.ps1" -ForegroundColor DarkGray
Write-Host "  Pipeline: convergence-loop.ps1 (parallel-aware execute)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  To disable: Set execute_parallel.enabled = false in agent-map.json" -ForegroundColor DarkGray
Write-Host ""
