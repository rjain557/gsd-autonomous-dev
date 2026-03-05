<#
.SYNOPSIS
    GSD Supervisor Wrapper for Convergence Pipeline
    Wraps convergence-loop.ps1 with autonomous self-healing recovery.
#>
param(
    [int]$MaxIterations = 20, [int]$StallThreshold = 3, [int]$BatchSize = 8,
    [int]$ThrottleSeconds = 30,
    [string]$NtfyTopic = "",
    [switch]$DryRun, [switch]$SkipInit, [switch]$SkipResearch, [switch]$SkipSpecCheck,
    [switch]$AutoResolve, [switch]$ForceCodeReview,
    [int]$SupervisorAttempts = 5,
    [switch]$NoSupervisor
)

$GlobalDir = Join-Path $env:USERPROFILE ".gsd-global"

# Load modules
. "$GlobalDir\lib\modules\resilience.ps1"
if (Test-Path "$GlobalDir\lib\modules\supervisor.ps1") {
    . "$GlobalDir\lib\modules\supervisor.ps1"
}

if ($NoSupervisor -or -not (Get-Command Invoke-SupervisorLoop -ErrorAction SilentlyContinue)) {
    # Direct pipeline invocation (backward compatible)
    & "$GlobalDir\scripts\convergence-loop.ps1" -MaxIterations $MaxIterations `
        -StallThreshold $StallThreshold -BatchSize $BatchSize `
        -ThrottleSeconds $ThrottleSeconds -NtfyTopic $NtfyTopic `
        -DryRun:$DryRun -SkipInit:$SkipInit -SkipResearch:$SkipResearch `
        -SkipSpecCheck:$SkipSpecCheck -AutoResolve:$AutoResolve -ForceCodeReview:$ForceCodeReview
    return
}

$originalParams = @{
    MaxIterations = $MaxIterations
    StallThreshold = $StallThreshold
    BatchSize = $BatchSize
    ThrottleSeconds = $ThrottleSeconds
    NtfyTopic = $NtfyTopic
    DryRun = $DryRun.IsPresent
    SkipInit = $SkipInit.IsPresent
    SkipResearch = $SkipResearch.IsPresent
    SkipSpecCheck = $SkipSpecCheck.IsPresent
    AutoResolve = $AutoResolve.IsPresent
    ForceCodeReview = $ForceCodeReview.IsPresent
}

Invoke-SupervisorLoop -Pipeline "converge" -OriginalParams $originalParams `
    -MaxAttempts $SupervisorAttempts
