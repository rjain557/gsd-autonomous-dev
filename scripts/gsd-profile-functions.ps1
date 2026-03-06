function gsd-converge {
    param(
        [int]$MaxIterations = 20, [int]$StallThreshold = 3, [int]$BatchSize = 8,
        [int]$ThrottleSeconds = 30, [string]$NtfyTopic = "",
        [switch]$DryRun, [switch]$SkipInit, [switch]$SkipResearch,
        [switch]$SkipSpecCheck, [switch]$AutoResolve, [switch]$ForceCodeReview,
        [string]$Scope = "", [switch]$Incremental,
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
    if ($Scope)         { $gsdArgs += "-Scope"; $gsdArgs += $Scope }
    if ($Incremental)   { $gsdArgs += "-Incremental" }
    if ($NoSupervisor) { $gsdArgs += "-NoSupervisor" }
    # Use pwsh (PS7) if available, otherwise fall back to current session
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) { & pwsh @gsdArgs } else { & $script -MaxIterations $MaxIterations -StallThreshold $StallThreshold -BatchSize $BatchSize -ThrottleSeconds $ThrottleSeconds -NtfyTopic $NtfyTopic -DryRun:$DryRun -SkipInit:$SkipInit -SkipResearch:$SkipResearch -SkipSpecCheck:$SkipSpecCheck -AutoResolve:$AutoResolve -ForceCodeReview:$ForceCodeReview -Scope $Scope -Incremental:$Incremental -SupervisorAttempts $SupervisorAttempts -NoSupervisor:$NoSupervisor }
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

    # Detect Figma version
    $figmaBase = Join-Path $repoRoot "design\figma"
    if (Test-Path $figmaBase) {
        $latest = Get-ChildItem -Path $figmaBase -Directory |
            Where-Object { $_.Name -match '^v(\d+)$' } |
            Sort-Object { [int]($_.Name -replace '^v', '') } -Descending |
            Select-Object -First 1
        if ($latest) {
            Write-Host "  Figma:      $($latest.Name)" -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    Write-Host "  Commands:" -ForegroundColor Yellow
    Write-Host "    gsd-blueprint              Greenfield generation" -ForegroundColor White
    Write-Host "    gsd-converge               Convergence loop" -ForegroundColor White
    Write-Host "    gsd-update                 Add new features (incremental)" -ForegroundColor White
    Write-Host "    gsd-fix `"bug desc`"          Quick bug fix mode" -ForegroundColor White
    Write-Host "    gsd-costs                  Token cost calculator" -ForegroundColor White
    Write-Host "    gsd-status                 This screen" -ForegroundColor White
    Write-Host ""
}

function gsd-assess {
    param([switch]$DryRun)
    $params = @{}
    if ($DryRun) { $params.DryRun = $true }
    & "$env:USERPROFILE\.gsd-global\blueprint\scripts\assess.ps1" @params
}






function gsd-fix {
    param([Parameter(ValueFromRemainingArguments)][string[]]$BugDescriptions, [string]$File = "")
    $script = "$env:USERPROFILE\.gsd-global\scripts\gsd-fix.ps1"
    if (-not (Test-Path $script)) { Write-Host "[ERROR] gsd-fix.ps1 not found. Run install-gsd-all.ps1 first." -ForegroundColor Red; return }
    $params = @{}
    if ($File)              { $params.File = $File }
    if ($BugDescriptions)   { $params.BugDescriptions = $BugDescriptions }
    & $script @params
}

function gsd-update {
    param([switch]$Incremental, [string]$Scope = "")
    $script = "$env:USERPROFILE\.gsd-global\scripts\gsd-update.ps1"
    if (-not (Test-Path $script)) { Write-Host "[ERROR] gsd-update.ps1 not found. Run install-gsd-all.ps1 first." -ForegroundColor Red; return }
    $params = @{}
    if ($Incremental) { $params.Incremental = $true }
    if ($Scope)       { $params.Scope = $Scope }
    & $script @params
}



function gsd-verify-requirements {
    <#
    .SYNOPSIS
        Partitioned extract + cross-verify requirements extraction.
        Each of 3 agents reads 1/3 of spec files, then a different agent verifies.
    .EXAMPLE
        gsd-verify-requirements
        gsd-verify-requirements -DryRun
        gsd-verify-requirements -SkipAgent gemini
        gsd-verify-requirements -ChunkSize 5
        gsd-verify-requirements -SkipVerify
    #>
    param(
        [string]$SkipAgent = "",
        [int]$ChunkSize = 0,
        [switch]$DryRun,
        [switch]$PreserveExisting,
        [switch]$SkipVerify
    )

    $repoRoot = (Get-Location).Path
    $gsdDir = Join-Path $repoRoot ".gsd"
    $globalDir = Join-Path $env:USERPROFILE ".gsd-global"

    @($gsdDir, "$gsdDir\health", "$gsdDir\logs", "$gsdDir\specs",
      "$gsdDir\code-review", "$gsdDir\research", "$gsdDir\generation-queue",
      "$gsdDir\agent-handoff") | ForEach-Object {
        if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
    }

    $healthFile = Join-Path $gsdDir "health\health-current.json"
    if (-not (Test-Path $healthFile)) {
        @{ health_score=0; total_requirements=0; satisfied=0; partial=0; not_started=0; iteration=0 } |
            ConvertTo-Json | Set-Content $healthFile -Encoding UTF8
    }

    . "$globalDir\lib\modules\resilience.ps1"
    if (Test-Path "$globalDir\lib\modules\interfaces.ps1") { . "$globalDir\lib\modules\interfaces.ps1" }
    if (Test-Path "$globalDir\lib\modules\interface-wrapper.ps1") { . "$globalDir\lib\modules\interface-wrapper.ps1" }

    # Override chunk size if specified
    if ($ChunkSize -gt 0) {
        $cfgPath = Join-Path $globalDir "config\global-config.json"
        if (Test-Path $cfgPath) {
            try {
                $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
                if ($cfg.council_requirements) {
                    $cfg.council_requirements.chunk_size = $ChunkSize
                    $cfg | ConvertTo-Json -Depth 10 | Set-Content $cfgPath -Encoding UTF8
                }
            } catch {}
        }
    }

    Write-Host ""
    Write-Host "=========================================================" -ForegroundColor Cyan
    Write-Host "  GSD Council Requirements Verification" -ForegroundColor Cyan
    Write-Host "  Partitioned Extract + Cross-Verify" -ForegroundColor Cyan
    Write-Host "=========================================================" -ForegroundColor Cyan
    Write-Host "  Repo: $repoRoot" -ForegroundColor White
    Write-Host ""

    $cliChecks = @("claude", "codex", "gemini") | Where-Object { $_ -ne $SkipAgent }
    foreach ($cli in $cliChecks) {
        $available = $null -ne (Get-Command $cli -ErrorAction SilentlyContinue)
        if ($available) {
            Write-Host "  [OK] $cli available" -ForegroundColor Green
        } else {
            Write-Host "  [!!] $cli not found (optional)" -ForegroundColor DarkYellow
        }
    }
    Write-Host ""

    $matrixFile = Join-Path $gsdDir "health\requirements-matrix.json"
    if ($PreserveExisting -and (Test-Path $matrixFile)) {
        $backupPath = "$matrixFile.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item $matrixFile $backupPath
        Write-Host "  [OK] Existing matrix backed up" -ForegroundColor DarkGreen
    }

    if (Get-Command Update-FileMap -ErrorAction SilentlyContinue) {
        Write-Host "  [MAP] Generating file map..." -ForegroundColor DarkGray
        Update-FileMap -Root $repoRoot -GsdPath $gsdDir 2>$null | Out-Null
    }

    # Use medium reasoning for bulk spec scanning (xhigh is too slow for file extraction)
    $env:GSD_CODEX_EFFORT = "medium"
    $callResult = Invoke-CouncilRequirements -RepoRoot $repoRoot -GsdDir $gsdDir `
        -DryRun:$DryRun -UseJobs $false -SkipAgent $SkipAgent -SkipVerify:$SkipVerify
    $env:GSD_CODEX_EFFORT = ""

    Write-Host ""
    if ($callResult.Success -and -not $DryRun -and (Test-Path $matrixFile)) {
        $matrix = Get-Content $matrixFile -Raw | ConvertFrom-Json
        Write-Host "  ========================================" -ForegroundColor Green
        Write-Host "  REQUIREMENTS VERIFIED SUCCESSFULLY" -ForegroundColor Green
        Write-Host "  ========================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "  Total:      $($matrix.meta.total_requirements) requirements" -ForegroundColor White
        Write-Host "  Health:     $($matrix.meta.health_score)%" -ForegroundColor White
        Write-Host "  Agents:     $($callResult.AgentsSucceeded) participated" -ForegroundColor White
        Write-Host ""

        $high = @($matrix.requirements | Where-Object { $_.confidence -eq "high" }).Count
        $med  = @($matrix.requirements | Where-Object { $_.confidence -eq "medium" }).Count
        $low  = @($matrix.requirements | Where-Object { $_.confidence -eq "low" }).Count

        Write-Host "  Confidence:" -ForegroundColor Yellow
        Write-Host "    High:   $high (confirmed by verifier)" -ForegroundColor Green
        Write-Host "    Medium: $med (added or corrected by verifier)" -ForegroundColor Yellow
        Write-Host "    Low:    $low (unverified)" -ForegroundColor DarkGray
        Write-Host ""

        Write-Host "  Output:" -ForegroundColor DarkGray
        Write-Host "    Matrix: $matrixFile" -ForegroundColor DarkGray
        Write-Host "    Report: $(Join-Path $gsdDir 'health\council-requirements-report.md')" -ForegroundColor DarkGray
        Write-Host ""
    } elseif ($callResult.Success -and $DryRun) {
        Write-Host "  [DRY RUN] Pre-flight passed." -ForegroundColor Green
        Write-Host "  Run without -DryRun to execute." -ForegroundColor DarkGray
        Write-Host ""
    } else {
        Write-Host "  [FAIL] Requirements extraction failed" -ForegroundColor Red
        Write-Host "  Error: $($callResult.Error)" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Try:" -ForegroundColor DarkGray
        Write-Host "    gsd-verify-requirements -ChunkSize 5         # Smaller chunks" -ForegroundColor DarkGray
        Write-Host "    gsd-verify-requirements -SkipVerify          # Extract only, no cross-check" -ForegroundColor DarkGray
        Write-Host "    gsd-verify-requirements -SkipAgent gemini    # Skip unavailable agent" -ForegroundColor DarkGray
    }
}
