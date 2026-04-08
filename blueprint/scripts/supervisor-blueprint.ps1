<#
.SYNOPSIS
    GSD Supervisor Wrapper for Blueprint Pipeline
    Wraps blueprint-pipeline.ps1 with autonomous self-healing recovery.
#>
param(
    [int]$MaxIterations = 30, [int]$StallThreshold = 3, [int]$BatchSize = 15,
    [int]$ThrottleSeconds = 30,
    [string]$NtfyTopic = "",
    [switch]$DryRun, [switch]$BlueprintOnly, [switch]$BuildOnly, [switch]$VerifyOnly,
    [switch]$SkipSpecCheck, [switch]$AutoResolve,
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
    & "$GlobalDir\blueprint\scripts\blueprint-pipeline.ps1" -MaxIterations $MaxIterations `
        -StallThreshold $StallThreshold -BatchSize $BatchSize `
        -ThrottleSeconds $ThrottleSeconds -NtfyTopic $NtfyTopic `
        -DryRun:$DryRun -BlueprintOnly:$BlueprintOnly -BuildOnly:$BuildOnly `
        -VerifyOnly:$VerifyOnly -SkipSpecCheck:$SkipSpecCheck -AutoResolve:$AutoResolve
    return
}

$originalParams = @{
    MaxIterations = $MaxIterations
    StallThreshold = $StallThreshold
    BatchSize = $BatchSize
    ThrottleSeconds = $ThrottleSeconds
    NtfyTopic = $NtfyTopic
    DryRun = $DryRun.IsPresent
    BlueprintOnly = $BlueprintOnly.IsPresent
    BuildOnly = $BuildOnly.IsPresent
    VerifyOnly = $VerifyOnly.IsPresent
    SkipSpecCheck = $SkipSpecCheck.IsPresent
    AutoResolve = $AutoResolve.IsPresent
}

Invoke-SupervisorLoop -Pipeline "blueprint" -OriginalParams $originalParams `
    -MaxAttempts $SupervisorAttempts
