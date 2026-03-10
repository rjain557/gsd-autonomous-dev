<#
.SYNOPSIS
    GSD V3 Supervisor - Health scoring, stall detection, requirement tracking, notifications
.DESCRIPTION
    Manages pipeline health state, detects stalls, tracks requirement satisfaction.
    Fixes V2 issues:
    - V2 calculated health as iterations_completed/total (wrong — should be requirements satisfied)
    - V2 had no per-requirement tracking
    - V2 stall detection was too simple
    - V2 had no regression detection for post-launch modes
#>

# ============================================================
# HEALTH SCORING
# ============================================================

function Update-HealthScore {
    param([string]$GsdDir)

    $matrixPath = Join-Path $GsdDir "requirements/requirements-matrix.json"
    if (-not (Test-Path $matrixPath)) {
        return @{ score = 0; total = 0; satisfied = 0; partial = 0; not_started = 0 }
    }

    try {
        $matrix = Get-Content $matrixPath -Raw | ConvertFrom-Json
        $reqs = if ($matrix.requirements) { $matrix.requirements } else { @() }

        $total = $reqs.Count
        $satisfied = ($reqs | Where-Object { $_.status -eq "satisfied" }).Count
        $partial = ($reqs | Where-Object { $_.status -eq "partial" }).Count
        $notStarted = ($reqs | Where-Object { $_.status -eq "not_started" }).Count

        $score = if ($total -gt 0) {
            [math]::Round(($satisfied * 1.0 + $partial * 0.5) / $total * 100, 1)
        } else { 0 }

        $health = @{
            score       = $score
            total       = $total
            satisfied   = $satisfied
            partial     = $partial
            not_started = $notStarted
            timestamp   = (Get-Date -Format "o")
        }

        $healthDir = Join-Path $GsdDir "health"
        if (-not (Test-Path $healthDir)) { New-Item -ItemType Directory -Path $healthDir -Force | Out-Null }
        $health | ConvertTo-Json | Set-Content (Join-Path $healthDir "health-current.json") -Encoding UTF8

        return $health
    }
    catch {
        Write-Host "  [WARN] Health calculation failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
        return @{ score = 0; total = 0; satisfied = 0; partial = 0; not_started = 0 }
    }
}

function Save-HealthHistory {
    param([string]$GsdDir, [int]$Iteration, [double]$Score, [double]$Delta)

    $entry = @{
        iteration = $Iteration
        score     = $Score
        delta     = $Delta
        timestamp = (Get-Date -Format "o")
    } | ConvertTo-Json -Compress

    $historyPath = Join-Path $GsdDir "health/health-history.jsonl"
    Add-Content -Path $historyPath -Value $entry -Encoding UTF8
}

# ============================================================
# STALL DETECTION
# ============================================================

function Test-StallDetected {
    param([string]$GsdDir, [int]$StallThreshold = 3)

    $historyPath = Join-Path $GsdDir "health/health-history.jsonl"
    if (-not (Test-Path $historyPath)) { return @{ Stalled = $false } }

    try {
        $lines = Get-Content $historyPath -Encoding UTF8 | Where-Object { $_.Trim() }
        $entries = $lines | ForEach-Object { $_ | ConvertFrom-Json }

        if ($entries.Count -lt $StallThreshold) {
            return @{ Stalled = $false; Reason = "Not enough history" }
        }

        $recent = $entries | Select-Object -Last $StallThreshold
        $allNonPositive = ($recent | Where-Object { $_.delta -le 0 }).Count -eq $StallThreshold

        if ($allNonPositive) {
            return @{
                Stalled = $true
                Reason  = "No health improvement in last $StallThreshold iterations"
                Scores  = ($recent | ForEach-Object { $_.score })
            }
        }
        return @{ Stalled = $false }
    }
    catch { return @{ Stalled = $false } }
}

# ============================================================
# REGRESSION DETECTION
# ============================================================

function Take-RequirementSnapshot {
    param([string]$GsdDir)
    $snapshot = @{}
    $matrixPath = Join-Path $GsdDir "requirements/requirements-matrix.json"
    if (Test-Path $matrixPath) {
        try {
            $matrix = Get-Content $matrixPath -Raw | ConvertFrom-Json
            foreach ($req in $matrix.requirements) { $snapshot[$req.req_id] = $req.status }
        } catch {}
    }
    return $snapshot
}

function Test-RegressionDetected {
    param([string]$GsdDir, [hashtable]$BaselineSnapshot = @{})

    if ($BaselineSnapshot.Count -eq 0) { return @{ Regressed = $false; Items = @() } }

    $matrixPath = Join-Path $GsdDir "requirements/requirements-matrix.json"
    if (-not (Test-Path $matrixPath)) { return @{ Regressed = $false; Items = @() } }

    try {
        $matrix = Get-Content $matrixPath -Raw | ConvertFrom-Json
        $regressions = @()
        foreach ($req in $matrix.requirements) {
            $baseline = $BaselineSnapshot[$req.req_id]
            if ($baseline -eq "satisfied" -and $req.status -ne "satisfied") {
                $regressions += @{
                    req_id      = $req.req_id
                    was_status  = "satisfied"
                    now_status  = $req.status
                    description = $req.description
                }
            }
        }

        if ($regressions.Count -gt 0) {
            Write-Host "  [REGRESSION] $($regressions.Count) satisfied requirements regressed!" -ForegroundColor Red
            foreach ($r in $regressions) {
                Write-Host "    - $($r.req_id): satisfied -> $($r.now_status)" -ForegroundColor Red
            }
        }
        return @{ Regressed = ($regressions.Count -gt 0); Items = $regressions }
    }
    catch { return @{ Regressed = $false; Items = @() } }
}

# ============================================================
# REQUIREMENTS MATRIX MANAGEMENT
# ============================================================

function Add-BugRequirement {
    param(
        [string]$GsdDir, [string]$BugId, [string]$Description,
        [string]$Interface = "unknown", [hashtable]$Artifacts = @{}
    )

    $matrixPath = Join-Path $GsdDir "requirements/requirements-matrix.json"
    $matrix = if (Test-Path $matrixPath) {
        Get-Content $matrixPath -Raw | ConvertFrom-Json
    } else {
        @{ requirements = @(); total = 0; health_score = 0 }
    }

    $newReq = @{
        req_id        = $BugId;  source     = "bug_report"
        sdlc_phase    = "Phase-D-Implementation"
        description   = $Description; status = "not_started"
        depends_on    = @();     priority   = "critical"
        spec_version  = "fix";   interface  = $Interface
        bug_artifacts = $Artifacts; regression_test_required = $true
    }

    $reqs = [System.Collections.ArrayList]@()
    if ($matrix.requirements) { foreach ($r in $matrix.requirements) { $reqs.Add($r) | Out-Null } }
    $reqs.Add([PSCustomObject]$newReq) | Out-Null

    $matrix.requirements = $reqs.ToArray()
    $matrix.total = $reqs.Count
    $satisfied = ($reqs | Where-Object { $_.status -eq "satisfied" }).Count
    $partial = ($reqs | Where-Object { $_.status -eq "partial" }).Count
    $matrix.health_score = if ($reqs.Count -gt 0) {
        [math]::Round(($satisfied + $partial * 0.5) / $reqs.Count * 100, 1)
    } else { 0 }

    $matrix | ConvertTo-Json -Depth 10 | Set-Content $matrixPath -Encoding UTF8
    Write-Host "  [MATRIX] Added $BugId ($Interface)" -ForegroundColor Green
    return $newReq
}

function Add-IncrementalRequirements {
    param([string]$GsdDir, [array]$NewRequirements, [string]$SpecVersion = "v02")

    $matrixPath = Join-Path $GsdDir "requirements/requirements-matrix.json"
    if (-not (Test-Path $matrixPath)) { throw "Requirements matrix not found. Run gsd-blueprint first." }

    $matrix = Get-Content $matrixPath -Raw | ConvertFrom-Json
    $reqs = [System.Collections.ArrayList]@()
    foreach ($r in $matrix.requirements) { $reqs.Add($r) | Out-Null }

    $added = 0
    foreach ($newReq in $NewRequirements) {
        if ($reqs | Where-Object { $_.req_id -eq $newReq.req_id }) { continue }
        $newReq.spec_version = $SpecVersion
        $newReq.status = "not_started"
        $reqs.Add([PSCustomObject]$newReq) | Out-Null
        $added++
    }

    $matrix.requirements = $reqs.ToArray()
    $matrix.total = $reqs.Count
    $satisfied = ($reqs | Where-Object { $_.status -eq "satisfied" }).Count
    $partial = ($reqs | Where-Object { $_.status -eq "partial" }).Count
    $matrix.health_score = if ($reqs.Count -gt 0) {
        [math]::Round(($satisfied + $partial * 0.5) / $reqs.Count * 100, 1)
    } else { 0 }

    $matrix | ConvertTo-Json -Depth 10 | Set-Content $matrixPath -Encoding UTF8
    Write-Host "  [MATRIX] Added $added new requirements (spec_version: $SpecVersion)" -ForegroundColor Green

    # Drift report
    $driftPath = Join-Path $GsdDir "requirements/drift-report.md"
    $drift = "# Drift Report - $SpecVersion`n`nAdded: $added | Total: $($reqs.Count) | Health: $($matrix.health_score)%`n"
    foreach ($r in ($reqs | Where-Object { $_.spec_version -eq $SpecVersion })) {
        $drift += "- $($r.req_id): $($r.description)`n"
    }
    Set-Content $driftPath -Value $drift -Encoding UTF8
    return @{ Added = $added; Total = $reqs.Count; Health = $matrix.health_score }
}

# ============================================================
# SCOPE FILTERING
# ============================================================

function Get-ScopedRequirements {
    param([string]$GsdDir, [string]$Scope)

    $matrixPath = Join-Path $GsdDir "requirements/requirements-matrix.json"
    if (-not (Test-Path $matrixPath)) { return @() }
    $matrix = Get-Content $matrixPath -Raw | ConvertFrom-Json
    $reqs = $matrix.requirements

    if (-not $Scope) { return $reqs | Where-Object { $_.status -in @("not_started", "partial") } }

    $filters = $Scope -split '\s+AND\s+'
    $filtered = $reqs
    foreach ($filter in $filters) {
        if ($filter -match "^source:(.+)$") { $filtered = $filtered | Where-Object { $_.source -eq $Matches[1] } }
        elseif ($filter -match "^id:(.+)$") { $ids = $Matches[1] -split ','; $filtered = $filtered | Where-Object { $_.req_id -in $ids } }
        elseif ($filter -match "^interface:(.+)$") { $filtered = $filtered | Where-Object { $_.interface -eq $Matches[1] } }
        elseif ($filter -match "^spec_version:(.+)$") { $filtered = $filtered | Where-Object { $_.spec_version -eq $Matches[1] } }
    }
    return $filtered | Where-Object { $_.status -in @("not_started", "partial") }
}

# ============================================================
# NOTIFICATIONS
# ============================================================

$script:NtfyTopic = ""

function Initialize-Notifications {
    param([string]$Topic, [string]$RepoRoot)
    if ($Topic -eq "auto") { $script:NtfyTopic = "gsd-$((Split-Path $RepoRoot -Leaf).ToLower())" }
    elseif ($Topic) { $script:NtfyTopic = $Topic }
}

function Send-GsdNotification {
    param([string]$Title, [string]$Message, [string]$Tags = "robot", [string]$Priority = "default")
    if (-not $script:NtfyTopic) { return }
    try {
        Invoke-RestMethod -Uri "https://ntfy.sh/$($script:NtfyTopic)" -Method Post `
            -Headers @{ Title = $Title; Tags = $Tags; Priority = $Priority } `
            -Body $Message -TimeoutSec 5 -ErrorAction SilentlyContinue | Out-Null
    } catch {}
}

# ============================================================
# ESCALATION TRACKING
# ============================================================

$script:EscalationCount = @{ opus = 0; codex = 0 }

function Test-EscalationAllowed {
    param([ValidateSet("opus","codex")][string]$Type, [int]$MaxOpus = 10, [int]$MaxCodex = 5)
    $max = if ($Type -eq "opus") { $MaxOpus } else { $MaxCodex }
    return $script:EscalationCount[$Type] -lt $max
}

function Add-Escalation {
    param([ValidateSet("opus","codex")][string]$Type)
    $script:EscalationCount[$Type]++
}
