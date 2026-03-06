function gsd-converge {
    param(
        [int]$MaxIterations = 20, [int]$StallThreshold = 3, [int]$BatchSize = 8,
        [int]$ThrottleSeconds = 30, [string]$NtfyTopic = "",
        [switch]$DryRun, [switch]$SkipInit, [switch]$SkipResearch,
        [switch]$SkipSpecCheck, [switch]$AutoResolve, [switch]$ForceCodeReview,
        [int]$SupervisorAttempts = 5, [switch]$NoSupervisor
    )
    $script = "$env:USERPROFILE\.gsd-global\scripts\supervisor-converge.ps1"
    if (-not (Test-Path $script)) { $script = "$env:USERPROFILE\.gsd-global\scripts\convergence-loop.ps1" }
    $gsdArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $script,
        "-MaxIterations", $MaxIterations, "-StallThreshold", $StallThreshold, "-BatchSize", $BatchSize,
        "-ThrottleSeconds", $ThrottleSeconds, "-SupervisorAttempts", $SupervisorAttempts)
    if ($NtfyTopic)    { $gsdArgs += "-NtfyTopic"; $gsdArgs += $NtfyTopic }
    if ($DryRun)       { $gsdArgs += "-DryRun" }
    if ($SkipInit)     { $gsdArgs += "-SkipInit" }
    if ($SkipResearch) { $gsdArgs += "-SkipResearch" }
    if ($SkipSpecCheck){ $gsdArgs += "-SkipSpecCheck" }
    if ($AutoResolve)  { $gsdArgs += "-AutoResolve" }
    if ($ForceCodeReview) { $gsdArgs += "-ForceCodeReview" }
    if ($NoSupervisor) { $gsdArgs += "-NoSupervisor" }
    # Use pwsh (PS7) if available, otherwise fall back to current session
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) { & pwsh @gsdArgs } else { & $script -MaxIterations $MaxIterations -StallThreshold $StallThreshold -BatchSize $BatchSize -ThrottleSeconds $ThrottleSeconds -NtfyTopic $NtfyTopic -DryRun:$DryRun -SkipInit:$SkipInit -SkipResearch:$SkipResearch -SkipSpecCheck:$SkipSpecCheck -AutoResolve:$AutoResolve -ForceCodeReview:$ForceCodeReview -SupervisorAttempts $SupervisorAttempts -NoSupervisor:$NoSupervisor }
}

function gsd-init {
    Write-Host "Initializing .gsd\ for current project..." -ForegroundColor Yellow
    & "$env:USERPROFILE\.gsd-global\scripts\convergence-loop.ps1" -MaxIterations 0
}

function gsd-remote {
    Write-Host "" -ForegroundColor Cyan
    Write-Host "  GSD Remote Control" -ForegroundColor Cyan
    Write-Host "  Scan the QR code with your phone to monitor from anywhere" -ForegroundColor DarkGray
    Write-Host "  Press Ctrl+C to stop remote session" -ForegroundColor DarkGray
    Write-Host "" -ForegroundColor Cyan
    claude remote-control
}

function gsd-costs {
    param(
        [string]$ProjectPath = "",
        [int]$TotalItems = 0, [int]$CompletedItems = 0, [int]$PartialItems = 0,
        [int]$BatchSize = 15, [string]$Pipeline = "blueprint",
        [double]$BatchEfficiency = 0.70, [double]$RetryRate = 0.15,
        [switch]$ShowComparison, [string]$ClaudeModel = "sonnet",
        [switch]$Detailed, [switch]$UpdatePricing,
        [switch]$ClientQuote, [double]$Markup = 7.0, [string]$ClientName = "Client Project"
    )
    $params = @{}
    if ($ProjectPath) { $params.ProjectPath = $ProjectPath }
    if ($TotalItems -gt 0) { $params.TotalItems = $TotalItems }
    if ($CompletedItems -gt 0) { $params.CompletedItems = $CompletedItems }
    if ($PartialItems -gt 0) { $params.PartialItems = $PartialItems }
    $params.BatchSize = $BatchSize
    $params.Pipeline = $Pipeline
    $params.BatchEfficiency = $BatchEfficiency
    $params.RetryRate = $RetryRate
    $params.ClaudeModel = $ClaudeModel
    if ($ShowComparison) { $params.ShowComparison = $true }
    if ($Detailed) { $params.Detailed = $true }
    if ($UpdatePricing) { $params.UpdatePricing = $true }
    if ($ClientQuote) { $params.ClientQuote = $true }
    if ($Markup -ne 7.0) { $params.Markup = $Markup }
    if ($ClientName -ne "Client Project") { $params.ClientName = $ClientName }
    & "$env:USERPROFILE\.gsd-global\scripts\token-cost-calculator.ps1" @params
}

function gsd-blueprint {
    param(
        [int]$MaxIterations = 30, [int]$StallThreshold = 3, [int]$BatchSize = 15,
        [int]$ThrottleSeconds = 30, [string]$NtfyTopic = "",
        [switch]$DryRun, [switch]$BlueprintOnly, [switch]$BuildOnly,
        [switch]$VerifyOnly, [switch]$SkipSpecCheck, [switch]$AutoResolve,
        [int]$SupervisorAttempts = 5, [switch]$NoSupervisor
    )
    $script = "$env:USERPROFILE\.gsd-global\blueprint\scripts\supervisor-blueprint.ps1"
    if (-not (Test-Path $script)) { $script = "$env:USERPROFILE\.gsd-global\blueprint\scripts\blueprint-pipeline.ps1" }
    $gsdArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $script,
        "-MaxIterations", $MaxIterations, "-StallThreshold", $StallThreshold, "-BatchSize", $BatchSize,
        "-ThrottleSeconds", $ThrottleSeconds, "-SupervisorAttempts", $SupervisorAttempts)
    if ($NtfyTopic)    { $gsdArgs += "-NtfyTopic"; $gsdArgs += $NtfyTopic }
    if ($DryRun)       { $gsdArgs += "-DryRun" }
    if ($BlueprintOnly){ $gsdArgs += "-BlueprintOnly" }
    if ($BuildOnly)    { $gsdArgs += "-BuildOnly" }
    if ($VerifyOnly)   { $gsdArgs += "-VerifyOnly" }
    if ($SkipSpecCheck){ $gsdArgs += "-SkipSpecCheck" }
    if ($AutoResolve)  { $gsdArgs += "-AutoResolve" }
    if ($NoSupervisor) { $gsdArgs += "-NoSupervisor" }
    # Use pwsh (PS7) if available, otherwise fall back to current session
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) { & pwsh @gsdArgs } else { & $script -MaxIterations $MaxIterations -StallThreshold $StallThreshold -BatchSize $BatchSize -ThrottleSeconds $ThrottleSeconds -NtfyTopic $NtfyTopic -DryRun:$DryRun -BlueprintOnly:$BlueprintOnly -BuildOnly:$BuildOnly -VerifyOnly:$VerifyOnly -SkipSpecCheck:$SkipSpecCheck -AutoResolve:$AutoResolve -SupervisorAttempts $SupervisorAttempts -NoSupervisor:$NoSupervisor }
}

function gsd-status {
    Write-Host ""
    $repoRoot = (Get-Location).Path
    $bpHealth = Join-Path $repoRoot ".gsd\blueprint\health.json"
    $gsdHealth = Join-Path $repoRoot ".gsd\health\health-current.json"

    Write-Host "  [CHART] GSD Status: $repoRoot" -ForegroundColor Cyan
    Write-Host "  -------------------------------------" -ForegroundColor DarkGray

    if (Test-Path $bpHealth) {
        $h = Get-Content $bpHealth -Raw | ConvertFrom-Json
        $bar = "#" * [math]::Floor($h.health / 5)
        $pad = "." * (20 - [math]::Floor($h.health / 5))
        Write-Host "  Blueprint:  [$bar$pad] $($h.health)% ($($h.completed)/$($h.total) items)" -ForegroundColor Blue
        Write-Host "              Tier $($h.current_tier): $($h.current_tier_name)" -ForegroundColor DarkGray
    } else {
        Write-Host "  Blueprint:  not initialized" -ForegroundColor DarkGray
    }

    if (Test-Path $gsdHealth) {
        $h = Get-Content $gsdHealth -Raw | ConvertFrom-Json
        $bar = "#" * [math]::Floor($h.health_score / 5)
        $pad = "." * (20 - [math]::Floor($h.health_score / 5))
        Write-Host "  GSD Health: [$bar$pad] $($h.health_score)% ($($h.satisfied)/$($h.total_requirements) reqs)" -ForegroundColor Green
    } else {
        Write-Host "  GSD Health: not initialized" -ForegroundColor DarkGray
    }

    # Detect latest design deliverable version across supported interface folders.
    $designRoot = Join-Path $repoRoot "design"
    if (Test-Path $designRoot) {
        $latest = Get-ChildItem -Path $designRoot -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                $ifaceDir = $_
                Get-ChildItem -Path $ifaceDir.FullName -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match '^v(\d+)$' } |
                    ForEach-Object {
                        [pscustomobject]@{
                            Interface = $ifaceDir.Name
                            Version = $_.Name
                            SortVersion = [int]($_.Name -replace '^v', '')
                        }
                    }
            } |
            Sort-Object SortVersion -Descending |
            Select-Object -First 1
        if ($latest) {
            Write-Host "  Design:     $($latest.Interface)\$($latest.Version)" -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    Write-Host "  Commands:" -ForegroundColor Yellow
    Write-Host "    gsd-blueprint              Greenfield generation" -ForegroundColor White
    Write-Host "    gsd-converge               Maintenance loop" -ForegroundColor White
    Write-Host "    gsd-status                 This screen" -ForegroundColor White
    Write-Host ""
}

function gsd-assess {
    param([switch]$DryRun)
    $params = @{}
    if ($DryRun) { $params.DryRun = $true }
    & "$env:USERPROFILE\.gsd-global\blueprint\scripts\assess.ps1" @params
}

