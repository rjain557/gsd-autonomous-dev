# ===============================================================
# GSD v2.0 Pipeline - Requirements-First Autonomous Development
# Unified 10-step pipeline replacing convergence + blueprint
# Usage: powershell -ExecutionPolicy Bypass -File pipeline.ps1 -RepoRoot "C:\repos\project"
# ===============================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [string]$NtfyTopic = "auto",
    [int]$StartStep = 1,
    [int]$StartIteration = 1,
    [switch]$SkipSpecGate
)

$ErrorActionPreference = "Stop"
$pipelineStart = Get-Date

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  GSD v2.0 - Requirements-First Pipeline" -ForegroundColor Cyan
Write-Host "============================================`n" -ForegroundColor Cyan

# -- Resolve paths --
$gsdGlobalDir = Join-Path $env:USERPROFILE ".gsd-global"
$v2Dir = Join-Path $gsdGlobalDir "v2"
$RepoRoot = (Resolve-Path $RepoRoot).Path
$GsdDir = Join-Path $RepoRoot ".gsd"

Write-Host "  Repo: $RepoRoot" -ForegroundColor DarkGray
Write-Host "  .gsd: $GsdDir" -ForegroundColor DarkGray

# -- Ensure .gsd directory structure --
$subdirs = @("specs", "requirements", "research", "plans", "iterations",
             "iterations\execution-log", "iterations\build-results", "iterations\reviews",
             "health", "costs", "supervisor", "logs")
foreach ($sub in $subdirs) {
    $dir = Join-Path $GsdDir $sub
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

# -- Load modules --
$modulesDir = Join-Path $v2Dir "lib\modules"
. (Join-Path $modulesDir "api-agents.ps1")
. (Join-Path $modulesDir "agent-router.ps1")
. (Join-Path $modulesDir "wave-executor.ps1")
. (Join-Path $modulesDir "notifications.ps1")

# Try to load resilience (may be v1.5 adapted or v2)
$resiliencePath = Join-Path $modulesDir "resilience.ps1"
if (-not (Test-Path $resiliencePath)) {
    $resiliencePath = Join-Path $gsdGlobalDir "lib\modules\resilience.ps1"
}
if (Test-Path $resiliencePath) { . $resiliencePath }

# Try to load interfaces
$interfacesPath = Join-Path $gsdGlobalDir "lib\modules\interfaces.ps1"
if (Test-Path $interfacesPath) { . $interfacesPath }
$interfaceWrapperPath = Join-Path $gsdGlobalDir "lib\modules\interface-wrapper.ps1"
if (Test-Path $interfaceWrapperPath) { . $interfaceWrapperPath }

# -- Load config --
$configPath = Join-Path $v2Dir "config\global-config.json"
$Config = Get-Content $configPath -Raw | ConvertFrom-Json

$agentMapPath = Join-Path $v2Dir "config\agent-map.json"
$AgentMap = Get-Content $agentMapPath -Raw | ConvertFrom-Json

# -- Initialize --
Initialize-AgentRouter
Initialize-Notifications -Topic $NtfyTopic -RepoRoot $RepoRoot

# -- Pre-flight --
if (Get-Command Test-PreFlight -ErrorAction SilentlyContinue) {
    $preflight = Test-PreFlight -RepoRoot $RepoRoot -GsdDir $GsdDir
    if (-not $preflight) {
        Write-Host "`n  [XX] Pre-flight failed. Aborting." -ForegroundColor Red
        exit 1
    }
}

# -- Lock --
if (Get-Command New-GsdLock -ErrorAction SilentlyContinue) {
    New-GsdLock -GsdDir $GsdDir -Pipeline "v2"
}

# -- Detect interfaces --
$Interfaces = $null
$InterfaceContext = ""
if (Get-Command Find-ProjectInterfaces -ErrorAction SilentlyContinue) {
    $Interfaces = Find-ProjectInterfaces -RepoRoot $RepoRoot
    if (Get-Command Build-InterfaceContext -ErrorAction SilentlyContinue) {
        $InterfaceContext = Build-InterfaceContext -Interfaces $Interfaces
    }
}

# -- File map --
if (Get-Command Update-FileMap -ErrorAction SilentlyContinue) {
    Update-FileMap -RepoRoot $RepoRoot -GsdDir $GsdDir
}

# -- Check for checkpoint resume --
if (Get-Command Get-Checkpoint -ErrorAction SilentlyContinue) {
    $checkpoint = Get-Checkpoint -GsdDir $GsdDir
    if ($checkpoint -and $checkpoint.pipeline -eq "v2") {
        Write-Host "  Resuming from checkpoint: Step $($checkpoint.phase), Iteration $($checkpoint.iteration)" -ForegroundColor Yellow
        # Map checkpoint phase to step number
        if ($checkpoint.phase -match "^(\d+)") {
            $StartStep = [int]$Matches[1]
        }
        if ($checkpoint.iteration) {
            $StartIteration = $checkpoint.iteration
        }
    }
}

# -- Send start notification --
Send-GsdNotification -Title "GSD v2 Pipeline Started" `
    -Message "Repo: $(Split-Path $RepoRoot -Leaf)`nStarting at step $StartStep" `
    -Tags "rocket"

# -- Start heartbeat --
Start-HeartbeatMonitor -IntervalMinutes $Config.notifications.heartbeat_interval_minutes
Start-CommandListener

# ============================================================
# PIPELINE EXECUTION
# ============================================================

$stepsDir = Join-Path $v2Dir "scripts\steps"
$pipelineResult = @{ Success = $true; CompletedSteps = @(); FailedStep = $null }

try {
    # ---- STEP 1: Spec Quality Gate ----
    if ($StartStep -le 1 -and -not $SkipSpecGate) {
        $step1 = & (Join-Path $stepsDir "step-01-spec-gate.ps1") `
            -GsdDir $GsdDir -RepoRoot $RepoRoot -AgentMap $AgentMap -Config $Config `
            -InterfaceContext $InterfaceContext

        if (-not $step1.Success -and $step1.Error -eq "spec_blocked") {
            Write-Host "`n  Pipeline blocked at Step 1. Fix spec conflicts first." -ForegroundColor Red
            $pipelineResult.Success = $false
            $pipelineResult.FailedStep = "01-spec-quality-gate"
            throw "Spec quality gate blocked"
        }
        $pipelineResult.CompletedSteps += "01"
        Save-Checkpoint -GsdDir $GsdDir -Pipeline "v2" -Iteration 0 -Phase "01-complete" -Health 0 -BatchSize 0
    }

    # ---- STEP 2: Requirements Derivation ----
    if ($StartStep -le 2) {
        $step2 = & (Join-Path $stepsDir "step-02-derive-requirements.ps1") `
            -GsdDir $GsdDir -RepoRoot $RepoRoot -AgentMap $AgentMap -Config $Config `
            -InterfaceContext $InterfaceContext -Interfaces $Interfaces

        if (-not $step2.Success) {
            throw "Requirements derivation failed: $($step2.Error)"
        }
        $pipelineResult.CompletedSteps += "02"
        Save-Checkpoint -GsdDir $GsdDir -Pipeline "v2" -Iteration 0 -Phase "02-complete" -Health 0 -BatchSize 0
    }

    # ---- STEP 3: Requirements Reconciliation ----
    if ($StartStep -le 3) {
        $step3 = & (Join-Path $stepsDir "step-03-reconcile.ps1") `
            -GsdDir $GsdDir -RepoRoot $RepoRoot -AgentMap $AgentMap -Config $Config `
            -InterfaceContext $InterfaceContext

        if (-not $step3.Success) {
            throw "Requirements reconciliation failed: $($step3.Error)"
        }
        $pipelineResult.CompletedSteps += "03"
        Save-Checkpoint -GsdDir $GsdDir -Pipeline "v2" -Iteration 0 -Phase "03-complete" -Health 0 -BatchSize 0
    }

    # ---- STEP 4: Dependency Graph ----
    if ($StartStep -le 4) {
        $step4 = & (Join-Path $stepsDir "step-04-dependency-graph.ps1") `
            -GsdDir $GsdDir -RepoRoot $RepoRoot -AgentMap $AgentMap -Config $Config `
            -InterfaceContext $InterfaceContext

        if (-not $step4.Success) {
            throw "Dependency graph failed: $($step4.Error)"
        }
        $pipelineResult.CompletedSteps += "04"
        Save-Checkpoint -GsdDir $GsdDir -Pipeline "v2" -Iteration 0 -Phase "04-complete" -Health 0 -BatchSize 0
    }

    # ---- STEP 5: Token Forecaster ----
    if ($StartStep -le 5) {
        $step5 = & (Join-Path $stepsDir "step-05-token-forecast.ps1") `
            -GsdDir $GsdDir -RepoRoot $RepoRoot -AgentMap $AgentMap -Config $Config `
            -InterfaceContext $InterfaceContext

        if (-not $step5.Success) {
            throw "Token forecasting failed: $($step5.Error)"
        }
        $pipelineResult.CompletedSteps += "05"
        Save-Checkpoint -GsdDir $GsdDir -Pipeline "v2" -Iteration 0 -Phase "05-complete" -Health 0 -BatchSize 0
    }

    # ---- STEP 6: Requirement Decomposer ----
    if ($StartStep -le 6) {
        $oversizeIds = if ($step5 -and $step5.OversizeIds) { $step5.OversizeIds } else { @() }
        $step6 = & (Join-Path $stepsDir "step-06-decompose.ps1") `
            -GsdDir $GsdDir -RepoRoot $RepoRoot -AgentMap $AgentMap -Config $Config `
            -InterfaceContext $InterfaceContext -OversizeRequirements $oversizeIds

        # Step 6 can succeed even if skipped (no oversize reqs)
        $pipelineResult.CompletedSteps += "06"
        Save-Checkpoint -GsdDir $GsdDir -Pipeline "v2" -Iteration 0 -Phase "06-complete" -Health 0 -BatchSize 0
    }

    # ---- STEP 7a: Research ----
    if ($StartStep -le 7) {
        $step7a = & (Join-Path $stepsDir "step-07a-research.ps1") `
            -GsdDir $GsdDir -RepoRoot $RepoRoot -AgentMap $AgentMap -Config $Config `
            -InterfaceContext $InterfaceContext

        if (-not $step7a.Success) {
            throw "Research failed: $($step7a.Error)"
        }
        $pipelineResult.CompletedSteps += "07a"
        Save-Checkpoint -GsdDir $GsdDir -Pipeline "v2" -Iteration 0 -Phase "07a-complete" -Health 0 -BatchSize 0
    }

    # ---- STEP 7b: Plan ----
    if ($StartStep -le 7 -or $StartStep -eq 8) {
        # Step 8 here maps to 7b in the pipeline
        $step7b = & (Join-Path $stepsDir "step-07b-plan.ps1") `
            -GsdDir $GsdDir -RepoRoot $RepoRoot -AgentMap $AgentMap -Config $Config `
            -InterfaceContext $InterfaceContext

        if (-not $step7b.Success) {
            throw "Planning failed: $($step7b.Error)"
        }
        $pipelineResult.CompletedSteps += "07b"
        Save-Checkpoint -GsdDir $GsdDir -Pipeline "v2" -Iteration 0 -Phase "07b-complete" -Health 0 -BatchSize 0
    }

    # ---- STEP 8: Iteration Planner ----
    if ($StartStep -le 8) {
        $step8 = & (Join-Path $stepsDir "step-08-iteration-plan.ps1") `
            -GsdDir $GsdDir -RepoRoot $RepoRoot -AgentMap $AgentMap -Config $Config `
            -InterfaceContext $InterfaceContext

        if (-not $step8.Success) {
            throw "Iteration planning failed: $($step8.Error)"
        }
        $pipelineResult.CompletedSteps += "08"
        Save-Checkpoint -GsdDir $GsdDir -Pipeline "v2" -Iteration 0 -Phase "08-complete" -Health 0 -BatchSize 0
    }

    # ---- STEP 9: Execute Iterations ----
    if ($StartStep -le 9) {
        $step9 = & (Join-Path $stepsDir "step-09-execute-loop.ps1") `
            -GsdDir $GsdDir -RepoRoot $RepoRoot -AgentMap $AgentMap -Config $Config `
            -InterfaceContext $InterfaceContext -StartIteration $StartIteration

        $pipelineResult.CompletedSteps += "09"
        Save-Checkpoint -GsdDir $GsdDir -Pipeline "v2" -Iteration $step9.TotalIterations `
            -Phase "09-complete" -Health $step9.HealthScore -BatchSize 0
    }

    # ---- STEP 10: Final Validation ----
    if ($StartStep -le 10) {
        $step10 = & (Join-Path $stepsDir "step-10-final-validate.ps1") `
            -GsdDir $GsdDir -RepoRoot $RepoRoot -AgentMap $AgentMap -Config $Config

        $pipelineResult.CompletedSteps += "10"

        if ($step10.Success) {
            $pipelineResult.Success = $true
            Write-Host "`n============================================" -ForegroundColor Green
            Write-Host "  GSD v2.0 PIPELINE: CONVERGED!" -ForegroundColor Green
            Write-Host "============================================" -ForegroundColor Green
        }
        else {
            $pipelineResult.Success = $false
            $pipelineResult.FailedStep = "10-final-validation"
            Write-Host "`n  Pipeline completed but final validation failed" -ForegroundColor Yellow
        }
    }
}
catch {
    $pipelineResult.Success = $false
    if (-not $pipelineResult.FailedStep) {
        $pipelineResult.FailedStep = "unknown"
    }
    $pipelineResult.Error = $_.Exception.Message
    Write-Host "`n  [XX] Pipeline error: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    # Stop background monitors
    Stop-BackgroundMonitors

    # Remove lock
    if (Get-Command Remove-GsdLock -ErrorAction SilentlyContinue) {
        Remove-GsdLock -GsdDir $GsdDir
    }

    # Clear checkpoint on success
    if ($pipelineResult.Success -and (Get-Command Clear-Checkpoint -ErrorAction SilentlyContinue)) {
        Clear-Checkpoint -GsdDir $GsdDir
    }

    # Summary
    $elapsed = [math]::Round(((Get-Date) - $pipelineStart).TotalMinutes, 1)
    Write-Host "`n  Pipeline completed in ${elapsed} minutes" -ForegroundColor DarkGray
    Write-Host "  Steps completed: $($pipelineResult.CompletedSteps -join ' -> ')" -ForegroundColor DarkGray
    if ($pipelineResult.FailedStep) {
        Write-Host "  Failed at: $($pipelineResult.FailedStep)" -ForegroundColor Red
    }
}

return $pipelineResult
