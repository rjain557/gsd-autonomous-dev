<#
.SYNOPSIS
    GSD V3 Supervisor - Health scoring, stall detection, requirement tracking, notifications
.DESCRIPTION
    Manages pipeline health state, detects stalls, tracks requirement satisfaction.
    Fixes V2 issues:
    - V2 calculated health as iterations_completed/total (wrong -- should be requirements satisfied)
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

        $total = @($reqs).Count
        $satisfied = @($reqs | Where-Object { $_.status -eq "satisfied" }).Count
        $partial = @($reqs | Where-Object { $_.status -eq "partial" }).Count
        $notStarted = @($reqs | Where-Object { $_.status -eq "not_started" }).Count

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
            foreach ($req in $matrix.requirements) {
                $rid = if ($req.req_id) { $req.req_id } else { $req.id }
                if ($rid) { $snapshot[$rid] = $req.status }
            }
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
            $rid = if ($req.req_id) { $req.req_id } else { $req.id }
            $baseline = $BaselineSnapshot[$rid]
            if ($baseline -eq "satisfied" -and $req.status -ne "satisfied") {
                $regressions += @{
                    req_id      = $rid
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

    $active = if (-not $Scope) {
        @($reqs | Where-Object { $_.status -in @("not_started", "partial") })
    } else {
        $filtered = $reqs
        $filters = $Scope -split '\s+AND\s+'
        foreach ($filter in $filters) {
            # Case-insensitive matching to prevent silent 0-match convergence
            if ($filter -match "^source:(.+)$") { $filtered = $filtered | Where-Object { $_.source -ieq $Matches[1] } }
            elseif ($filter -match "^id:(.+)$") { $ids = $Matches[1] -split ','; $filtered = $filtered | Where-Object { ($_.req_id -in $ids) -or ($_.id -in $ids) } }
            elseif ($filter -match "^interface:(.+)$") { $filtered = $filtered | Where-Object { $_.interface -ieq $Matches[1] } }
            elseif ($filter -match "^spec_version:(.+)$") { $filtered = $filtered | Where-Object { $_.spec_version -ieq $Matches[1] } }
        }
        @($filtered | Where-Object { $_.status -in @("not_started", "partial") })
    }

    # Warn if scope filter matched 0 requirements -- likely a bug, not convergence
    if ($Scope -and $active.Count -eq 0 -and $reqs.Count -gt 0) {
        Write-Host "  [WARN] Scope filter '$Scope' matched 0 active requirements out of $($reqs.Count) total." -ForegroundColor Yellow
        Write-Host "         Check if filter values match matrix field values (case-insensitive)." -ForegroundColor Yellow
    }

    # Smart prioritization: not_started first, then partial; deprioritize items with high fail_count
    # Load fail tracker if it exists
    $failTrackerPath = Join-Path $GsdDir "requirements/fail-tracker.json"
    $failTracker = @{}
    if (Test-Path $failTrackerPath) {
        try {
            $ftData = Get-Content $failTrackerPath -Raw | ConvertFrom-Json
            foreach ($prop in $ftData.PSObject.Properties) { $failTracker[$prop.Name] = $prop.Value }
        } catch {}
    }

    # Sort: not_started before partial, then by fail_count ascending (fewer failures first)
    $sorted = @($active | Sort-Object @(
        @{ Expression = { if ($_.status -eq "not_started") { 0 } else { 1 } }; Ascending = $true },
        @{ Expression = { $rid = if ($_.id) { $_.id } else { $_.req_id }; if ($failTracker[$rid]) { $failTracker[$rid] } else { 0 } }; Ascending = $true },
        @{ Expression = { if ($_.priority -eq "high") { 0 } elseif ($_.priority -eq "medium") { 1 } else { 2 } }; Ascending = $true }
    ))

    return $sorted
}

# ============================================================
# NOTIFICATIONS
# ============================================================

$script:NtfyTopic = ""
$script:HeartbeatJob = $null
$script:ListenerJob = $null
$script:PipelineStartTime = $null

function Initialize-Notifications {
    param([string]$Topic, [string]$RepoRoot)

    $script:PipelineStartTime = Get-Date

    if ($Topic -eq "auto") {
        $username = if ($env:USERNAME) { $env:USERNAME } else { $env:USER }
        $repoName = Split-Path $RepoRoot -Leaf
        $safeName = ($repoName -replace '[^a-zA-Z0-9-]', '-').ToLower().Trim('-')
        $safeUser = ($username -replace '[^a-zA-Z0-9-]', '-').ToLower().Trim('-')
        $script:NtfyTopic = "gsd-$safeUser-$safeName"
    } elseif ($Topic) {
        $script:NtfyTopic = $Topic
    }

    Write-Host "  Notifications: ntfy.sh topic = $($script:NtfyTopic)" -ForegroundColor DarkGray
    Write-Host "  Subscribe: https://ntfy.sh/$($script:NtfyTopic)" -ForegroundColor DarkGray
}

function Send-GsdNotification {
    param([string]$Title, [string]$Message, [string]$Tags = "robot", [string]$Priority = "default")
    if (-not $script:NtfyTopic) { return }
    try {
        $headers = @{ "Title" = $Title; "Priority" = $Priority }
        if ($Tags) { $headers["Tags"] = $Tags }
        Invoke-RestMethod -Uri "https://ntfy.sh/$($script:NtfyTopic)" -Method Post `
            -Headers $headers -Body $Message `
            -TimeoutSec 10 -ErrorAction SilentlyContinue | Out-Null
    } catch {}
}

function Send-StepNotification {
    param([string]$StepId, [string]$Status, [string]$Details = "")

    $elapsed = if ($script:PipelineStartTime) {
        [math]::Round(((Get-Date) - $script:PipelineStartTime).TotalMinutes, 1)
    } else { 0 }

    $emoji = switch ($Status) {
        "complete" { "white_check_mark" }
        "failed"   { "x" }
        "skipped"  { "fast_forward" }
        default    { "hourglass_flowing_sand" }
    }

    $msg = "Step: $StepId`nStatus: $Status`nElapsed: ${elapsed}m"
    if ($Details) { $msg += "`n$Details" }
    Send-GsdNotification -Title "GSD V3: $StepId" -Message $msg -Tags $emoji
}

function Send-IterationNotification {
    param([int]$Iteration, [double]$Health, [double]$Delta, [string]$CostSummary = "")

    $elapsed = if ($script:PipelineStartTime) {
        [math]::Round(((Get-Date) - $script:PipelineStartTime).TotalMinutes, 1)
    } else { 0 }

    $msg = "Health: $Health% | Delta: $([math]::Round($Delta, 1))`nElapsed: ${elapsed}m"
    if ($CostSummary) { $msg += "`n$CostSummary" }
    $tags = if ($Delta -gt 0) { "chart_with_upwards_trend" } else { "warning" }
    Send-GsdNotification -Title "GSD V3: Iteration $Iteration" -Message $msg -Tags $tags
}

function Send-ConvergedNotification {
    param([int]$TotalIterations, [double]$Health, [string]$CostSummary = "")

    $elapsed = if ($script:PipelineStartTime) {
        [math]::Round(((Get-Date) - $script:PipelineStartTime).TotalMinutes, 1)
    } else { 0 }

    $msg = "ALL REQUIREMENTS SATISFIED!`nHealth: $Health%`nIterations: $TotalIterations`nTotal time: ${elapsed}m"
    if ($CostSummary) { $msg += "`n$CostSummary" }
    Send-GsdNotification -Title "GSD V3: CONVERGED!" -Message $msg -Tags "tada,white_check_mark" -Priority "high"
}

function Send-EscalationNotification {
    param([string]$Reason, [string]$Details = "")

    $msg = "HUMAN INTERVENTION NEEDED`nReason: $Reason"
    if ($Details) { $msg += "`n$Details" }
    Send-GsdNotification -Title "GSD V3: NEEDS HUMAN" -Message $msg -Tags "sos" -Priority "urgent"
}

function Start-HeartbeatMonitor {
    param([int]$IntervalMinutes = 10, [string]$GsdDir)

    if (-not $script:NtfyTopic) { return }

    $script:HeartbeatJob = Start-Job -ScriptBlock {
        param($Topic, $IntervalMs, $GsdDir)

        while ($true) {
            Start-Sleep -Milliseconds $IntervalMs
            try {
                # Read checkpoint for context
                $phase = "unknown"
                $iter = 0
                $health = 0
                $cpPath = Join-Path $GsdDir ".gsd-checkpoint.json"
                if (Test-Path $cpPath) {
                    $cp = Get-Content $cpPath -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
                    if ($cp) {
                        $phase = if ($cp.phase) { $cp.phase } else { "unknown" }
                        $iter = if ($cp.iteration) { $cp.iteration } else { 0 }
                        $health = if ($cp.health) { $cp.health } else { 0 }
                    }
                }

                # Read cost if available
                $costText = ""
                $costPath = Join-Path $GsdDir "costs/cost-summary.json"
                if (Test-Path $costPath) {
                    $cost = Get-Content $costPath -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
                    if ($cost -and $cost.total_usd) {
                        $costText = "Cost: `$$([math]::Round($cost.total_usd, 2))"
                    }
                }

                $repoName = Split-Path (Split-Path $GsdDir -Parent) -Leaf
                $msg = "[GSD-STATUS] $repoName | Iter $iter | Health: $health% | Phase: $phase | $(Get-Date -Format 'HH:mm')"
                if ($costText) { $msg += " | $costText" }

                $headers = @{
                    "Title"    = "[GSD] $phase Working"
                    "Priority" = "low"
                    "Tags"     = "hourglass_flowing_sand"
                }
                Invoke-RestMethod -Uri "https://ntfy.sh/$Topic" `
                    -Method Post -Body $msg -Headers $headers `
                    -TimeoutSec 10 -ErrorAction SilentlyContinue | Out-Null
            } catch { }
        }
    } -ArgumentList $script:NtfyTopic, ($IntervalMinutes * 60 * 1000), $GsdDir

    Write-Host "  Heartbeat monitor started (every ${IntervalMinutes}m)" -ForegroundColor DarkGray
}

function Start-CommandListener {
    param([string]$GsdDir)

    if (-not $script:NtfyTopic) { return }

    $script:ListenerJob = Start-Job -ScriptBlock {
        param($Topic, $GsdDir)

        $since = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        while ($true) {
            Start-Sleep -Seconds 15
            try {
                $msgs = Invoke-RestMethod -Uri "https://ntfy.sh/$Topic/json?since=$since&poll=1" `
                    -TimeoutSec 10 -ErrorAction SilentlyContinue

                if ($msgs) {
                    $lines = $msgs -split "`n" | Where-Object { $_.Trim() }
                    foreach ($line in $lines) {
                        try {
                            $msg = $line | ConvertFrom-Json
                            $text = if ($msg.message) { $msg.message.Trim().ToLower() } else { "" }

                            # Skip our own responses
                            if ($text -match "^\[GSD-STATUS\]" -or $text -match "^\[GSD-COSTS\]") {
                                if ($msg.time) { $since = $msg.time + 1 }
                                continue
                            }

                            # PROGRESS command
                            if ($text -eq "progress") {
                                $phase = "unknown"; $iter = 0; $health = 0; $costText = ""
                                $cpPath = Join-Path $GsdDir ".gsd-checkpoint.json"
                                if (Test-Path $cpPath) {
                                    $cp = Get-Content $cpPath -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
                                    if ($cp) { $phase = $cp.phase; $iter = $cp.iteration; $health = $cp.health }
                                }

                                # Health details
                                $healthPath = Join-Path $GsdDir "health/health-current.json"
                                $satisfied = 0; $partial = 0; $notStarted = 0; $total = 0
                                if (Test-Path $healthPath) {
                                    $h = Get-Content $healthPath -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
                                    if ($h) { $satisfied = $h.satisfied; $partial = $h.partial; $notStarted = $h.not_started; $total = $h.total }
                                }

                                # Cost
                                $costPath = Join-Path $GsdDir "costs/cost-summary.json"
                                if (Test-Path $costPath) {
                                    $cost = Get-Content $costPath -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
                                    if ($cost) { $costText = "Cost: `$$([math]::Round($cost.total_usd, 2))" }
                                }

                                $repoName = Split-Path (Split-Path $GsdDir -Parent) -Leaf
                                $body = "[GSD-STATUS] Progress Report`n$repoName | V3 pipeline`nHealth: $health% | Iter: $iter | Phase: $phase`nItems: $satisfied done / $partial partial / $notStarted todo (of $total)"
                                if ($costText) { $body += "`n$costText" }

                                $headers = @{ "Title" = "[GSD-STATUS] Progress"; "Tags" = "bar_chart" }
                                Invoke-RestMethod -Uri "https://ntfy.sh/$Topic" -Method Post -Body $body -Headers $headers -TimeoutSec 10 -ErrorAction SilentlyContinue | Out-Null
                            }

                            # TOKEN / COST command
                            if ($text -in @("token", "tokens", "cost", "costs")) {
                                $costPath = Join-Path $GsdDir "costs/cost-summary.json"
                                $body = "[GSD-COSTS] No cost data available"
                                if (Test-Path $costPath) {
                                    $cost = Get-Content $costPath -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
                                    if ($cost) {
                                        $body = "[GSD-COSTS] Token Cost Report`nTotal: `$$([math]::Round($cost.total_usd, 2))"
                                        if ($cost.total_tokens) { $body += "`nTokens: $([math]::Round($cost.total_tokens / 1000, 0))K" }
                                        if ($cost.api_calls) { $body += "`nAPI Calls: $($cost.api_calls)" }
                                        if ($cost.by_phase) {
                                            $body += "`n`nBy Phase:"
                                            foreach ($p in $cost.by_phase.PSObject.Properties) {
                                                $body += "`n  $($p.Name): `$$([math]::Round($p.Value.cost, 2)) ($($p.Value.calls) calls)"
                                            }
                                        }
                                    }
                                }
                                $headers = @{ "Title" = "[GSD-COSTS] Cost Report"; "Tags" = "money_with_wings" }
                                Invoke-RestMethod -Uri "https://ntfy.sh/$Topic" -Method Post -Body $body -Headers $headers -TimeoutSec 10 -ErrorAction SilentlyContinue | Out-Null
                            }

                            # WHATSAPP command -- restart bridge
                            if ($text -eq "whatsapp") {
                                $bridgeDir = Join-Path $env:USERPROFILE ".gsd-global\whatsapp-bridge"
                                $bridgeMjs = Join-Path $bridgeDir "bridge.mjs"
                                $killed = 0

                                if (Test-Path $bridgeMjs) {
                                    # Kill old bridge processes
                                    try {
                                        $stale = Get-CimInstance Win32_Process | Where-Object { $_.Name -eq "node.exe" -and $_.CommandLine -like "*bridge.mjs*" }
                                        foreach ($p in $stale) {
                                            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
                                            $killed++
                                        }
                                    } catch {}

                                    Start-Sleep -Seconds 3
                                    Start-Process -FilePath "node" -ArgumentList $bridgeMjs -WorkingDirectory $bridgeDir -WindowStyle Hidden
                                    $body = "[GSD] WhatsApp Bridge Restart`nKilled $killed old process(es), started new bridge"
                                } else {
                                    $body = "[GSD] WhatsApp bridge not found at $bridgeMjs"
                                }
                                $headers = @{ "Title" = "[GSD] WhatsApp Bridge"; "Tags" = "phone,recycle"; "Priority" = "high" }
                                Invoke-RestMethod -Uri "https://ntfy.sh/$Topic" -Method Post -Body $body -Headers $headers -TimeoutSec 10 -ErrorAction SilentlyContinue | Out-Null
                            }

                            if ($msg.time) { $since = $msg.time + 1 }
                        } catch { }
                    }
                }
            } catch { }
        }
    } -ArgumentList $script:NtfyTopic, $GsdDir

    Write-Host "  Command listener started (polling every 15s)" -ForegroundColor DarkGray
}

function Stop-BackgroundMonitors {
    if ($script:HeartbeatJob) {
        Stop-Job -Job $script:HeartbeatJob -ErrorAction SilentlyContinue
        Remove-Job -Job $script:HeartbeatJob -Force -ErrorAction SilentlyContinue
        $script:HeartbeatJob = $null
    }
    if ($script:ListenerJob) {
        Stop-Job -Job $script:ListenerJob -ErrorAction SilentlyContinue
        Remove-Job -Job $script:ListenerJob -Force -ErrorAction SilentlyContinue
        $script:ListenerJob = $null
    }
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
