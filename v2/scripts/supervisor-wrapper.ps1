# ===============================================================
# GSD v2.0 Supervisor Wrapper - Self-healing pipeline wrapper
# Wraps pipeline.ps1 with diagnosis, fix, and restart capability
# Usage: powershell -ExecutionPolicy Bypass -File supervisor-wrapper.ps1 -RepoRoot "C:\repos\project"
# ===============================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [string]$NtfyTopic = "auto",
    [int]$SupervisorAttempts = 5,
    [int]$StartStep = 1
)

$ErrorActionPreference = "Stop"
$supervisorStart = Get-Date

Write-Host "`n============================================" -ForegroundColor Magenta
Write-Host "  GSD v2.0 Supervisor" -ForegroundColor Magenta
Write-Host "  Max attempts: $SupervisorAttempts" -ForegroundColor Magenta
Write-Host "============================================`n" -ForegroundColor Magenta

$gsdGlobalDir = Join-Path $env:USERPROFILE ".gsd-global"
$v2Dir = Join-Path $gsdGlobalDir "v2"
$RepoRoot = (Resolve-Path $RepoRoot).Path
$GsdDir = Join-Path $RepoRoot ".gsd"

# Load modules for supervisor
$modulesDir = Join-Path $v2Dir "lib\modules"
. (Join-Path $modulesDir "api-agents.ps1")
. (Join-Path $modulesDir "agent-router.ps1")
. (Join-Path $modulesDir "notifications.ps1")

# Load v1.5 supervisor if available
$supervisorModulePath = Join-Path $gsdGlobalDir "lib\modules\supervisor.ps1"
$hasSupervisorModule = Test-Path $supervisorModulePath
if ($hasSupervisorModule) { . $supervisorModulePath }

Initialize-Notifications -Topic $NtfyTopic -RepoRoot $RepoRoot

$attempt = 0
$recovered = $false
$strategyHistory = @()

while ($attempt -lt $SupervisorAttempts -and -not $recovered) {
    $attempt++
    Write-Host "`n  --- Supervisor Attempt $attempt/$SupervisorAttempts ---" -ForegroundColor Magenta

    # Run pipeline
    $pipelineScript = Join-Path $v2Dir "scripts\pipeline.ps1"
    $pipelineArgs = @{
        RepoRoot = $RepoRoot
        NtfyTopic = $NtfyTopic
        StartStep = $StartStep
    }

    try {
        $result = & $pipelineScript @pipelineArgs

        if ($result.Success) {
            $recovered = $true
            Write-Host "`n  Pipeline CONVERGED on attempt $attempt!" -ForegroundColor Green
            break
        }

        # Pipeline failed — diagnose
        Write-Host "`n  Pipeline failed at step: $($result.FailedStep)" -ForegroundColor Yellow
        Write-Host "  Error: $($result.Error)" -ForegroundColor Yellow

        # Save last run summary
        $summaryPath = Join-Path $GsdDir "supervisor\last-run-summary.json"
        @{
            attempt = $attempt
            exit_reason = "failed"
            failed_step = $result.FailedStep
            error = $result.Error
            completed_steps = $result.CompletedSteps
            timestamp = (Get-Date -Format "o")
        } | ConvertTo-Json | Set-Content $summaryPath -Encoding UTF8

        # Layer 1: Pattern matching (free)
        Write-Host "  [L1] Analyzing error patterns..." -ForegroundColor DarkGray
        $errorStats = @{ category = "unknown"; confidence = 50 }

        if ($result.Error -match "spec_blocked") {
            $errorStats.category = "spec_conflict"
            $errorStats.confidence = 95
            Write-Host "    Category: Spec conflict (requires human intervention)" -ForegroundColor Red
            # Can't auto-fix spec conflicts
            break
        }
        elseif ($result.Error -match "auth_error|invalid.*key") {
            $errorStats.category = "auth_error"
            $errorStats.confidence = 95
            Write-Host "    Category: Auth error (requires human intervention)" -ForegroundColor Red
            break
        }
        elseif ($result.Error -match "token_limit|context.*window") {
            $errorStats.category = "token_overflow"
            $errorStats.confidence = 80
        }
        elseif ($result.Error -match "timeout|watchdog") {
            $errorStats.category = "timeout"
            $errorStats.confidence = 80
        }
        elseif ($result.Error -match "quota|rate_limit") {
            $errorStats.category = "quota_exhausted"
            $errorStats.confidence = 90
            Write-Host "    Category: Quota exhausted - waiting..." -ForegroundColor Yellow
            Start-Sleep -Seconds 300  # Wait 5 minutes
        }

        # Layer 2: AI diagnosis (if available)
        if ($hasSupervisorModule -and (Get-Command Invoke-SupervisorDiagnosis -ErrorAction SilentlyContinue)) {
            Write-Host "  [L2] AI diagnosis..." -ForegroundColor DarkGray
            Send-GsdNotification -Title "GSD v2: Supervisor Active" `
                -Message "Attempt $attempt - diagnosing failure at $($result.FailedStep)" `
                -Tags "robot_face" -Priority "low"

            try {
                $diagnosis = Invoke-SupervisorDiagnosis -GsdDir $GsdDir
                if ($diagnosis) {
                    Write-Host "    Root cause: $($diagnosis.root_cause)" -ForegroundColor Yellow
                    Write-Host "    Fix type: $($diagnosis.fix_type)" -ForegroundColor Yellow

                    # Layer 3: Apply fix
                    if ($diagnosis.fix_type -ne "escalate") {
                        # Check strategy deduplication
                        $strategyKey = "$($diagnosis.fix_type):$($diagnosis.root_cause)"
                        if ($strategyKey -in $strategyHistory) {
                            Write-Host "    [SKIP] Strategy already tried: $strategyKey" -ForegroundColor DarkYellow
                        }
                        else {
                            $strategyHistory += $strategyKey
                            Write-Host "  [L3] Applying fix..." -ForegroundColor DarkGray
                            Invoke-SupervisorFix -GsdDir $GsdDir -Diagnosis $diagnosis
                            Send-GsdNotification -Title "GSD v2: Supervisor Fixed" `
                                -Message "$($diagnosis.fix_type): $($diagnosis.root_cause)" `
                                -Tags "wrench"
                        }
                    }
                }
            }
            catch {
                Write-Host "    [WARN] Diagnosis failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
            }
        }
        else {
            # Simple recovery: adjust StartStep to resume from failed step
            Write-Host "  [L2] No supervisor module - simple retry from failed step" -ForegroundColor DarkGray
            if ($result.FailedStep -match "^(\d+)") {
                $StartStep = [int]$Matches[1]
            }
        }

        # Check for checkpoint to determine resume point
        $checkpointPath = Join-Path $GsdDir ".gsd-checkpoint.json"
        if (Test-Path $checkpointPath) {
            try {
                $cp = Get-Content $checkpointPath -Raw | ConvertFrom-Json
                if ($cp.phase -match "^(\d+)") {
                    $StartStep = [int]$Matches[1]
                }
            } catch {}
        }
    }
    catch {
        Write-Host "  [XX] Pipeline crashed: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Final status
$elapsed = [math]::Round(((Get-Date) - $supervisorStart).TotalMinutes, 1)

if ($recovered) {
    Write-Host "`n============================================" -ForegroundColor Green
    Write-Host "  SUPERVISOR: RECOVERED (attempt $attempt, ${elapsed}m)" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
    Send-GsdNotification -Title "GSD v2: RECOVERED!" `
        -Message "Converged on attempt $attempt in ${elapsed}m" `
        -Tags "tada,white_check_mark" -Priority "high"
}
else {
    Write-Host "`n============================================" -ForegroundColor Red
    Write-Host "  SUPERVISOR: EXHAUSTED after $attempt attempts (${elapsed}m)" -ForegroundColor Red
    Write-Host "  HUMAN INTERVENTION NEEDED" -ForegroundColor Red
    Write-Host "============================================" -ForegroundColor Red

    # Generate escalation report
    $escalation = @"
# GSD v2.0 Escalation Report
Generated: $(Get-Date -Format "o")
Repo: $RepoRoot
Attempts: $attempt
Total time: ${elapsed}m

## Strategies Tried
$($strategyHistory | ForEach-Object { "- $_" } | Out-String)

## Recommended Actions
1. Check .gsd/supervisor/last-run-summary.json for failure details
2. Check .gsd/logs/errors.jsonl for error patterns
3. Review spec quality report at .gsd/specs/spec-quality-report.json
4. Fix any spec conflicts manually, then re-run
"@
    Set-Content -Path (Join-Path $GsdDir "supervisor\escalation-report.md") -Value $escalation -Encoding UTF8

    Send-EscalationNotification -Reason "All $SupervisorAttempts recovery attempts exhausted" `
        -Details "Strategies tried: $($strategyHistory -join ', ')"
}
