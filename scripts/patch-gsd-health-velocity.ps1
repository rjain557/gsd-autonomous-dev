<#
.SYNOPSIS
    Patch #44: Health Velocity Monitor — detects stagnant/regressing health.
    Adds Test-HealthVelocity + Start/Stop-HealthVelocityMonitor to resilience.ps1.
    Wires Start-HealthVelocityMonitor into convergence-loop.ps1 startup.

.NOTES
    Install chain position: #44
    Depends on: resilience.ps1 (Send-GsdNotification, health-history.jsonl)
#>

param(
    [string]$GlobalDir = "$env:USERPROFILE\.gsd-global"
)

$ErrorActionPreference = 'Stop'

Write-Host "`n=== Patch #44: Health Velocity Monitor ===" -ForegroundColor Cyan

# ── 1. Append functions to resilience.ps1 ──
$resPath = Join-Path $GlobalDir "lib\modules\resilience.ps1"
$resContent = Get-Content $resPath -Raw

if ($resContent -match 'function Test-HealthVelocity') {
    Write-Host "  [SKIP] Test-HealthVelocity already present" -ForegroundColor DarkGray
} else {
    $functions = @'

# ===========================================
# HEALTH VELOCITY MONITOR (Patch #44)
# ===========================================
$script:VELOCITY_JOB = $null

function Test-HealthVelocity {
    <#
    .SYNOPSIS
        Reads last 5 health-history.jsonl entries. Returns object with stagnant/regression flags.
    #>
    param([string]$GsdDir)

    $histPath = Join-Path $GsdDir "health\health-history.jsonl"
    if (-not (Test-Path $histPath)) {
        return @{ stagnant = $false; regression = $false; entries = 0; satisfied_trend = @() }
    }

    $lines = Get-Content $histPath -Tail 5
    if ($lines.Count -lt 2) {
        return @{ stagnant = $false; regression = $false; entries = $lines.Count; satisfied_trend = @() }
    }

    $entries = @()
    foreach ($line in $lines) {
        try { $entries += ($line | ConvertFrom-Json) } catch {}
    }
    if ($entries.Count -lt 2) {
        return @{ stagnant = $false; regression = $false; entries = $entries.Count; satisfied_trend = @() }
    }

    $satTrend = @($entries | ForEach-Object {
        if ($_.satisfied) { [int]$_.satisfied } elseif ($_.health_score) { [int]$_.health_score } else { 0 }
    })

    # Check regression: any decrease from previous entry
    $regression = $false
    for ($i = 1; $i -lt $satTrend.Count; $i++) {
        if ($satTrend[$i] -lt $satTrend[$i - 1]) { $regression = $true; break }
    }

    # Check stagnation: last 3 entries have same satisfied count
    $stagnant = $false
    if ($satTrend.Count -ge 3) {
        $last3 = $satTrend[($satTrend.Count - 3)..($satTrend.Count - 1)]
        if (($last3 | Sort-Object -Unique).Count -eq 1) { $stagnant = $true }
    }

    # Velocity: satisfied per hour based on first and last entry timestamps
    $velocityPerHour = 0
    try {
        $firstTs = [datetime]::Parse($entries[0].timestamp)
        $lastTs  = [datetime]::Parse($entries[$entries.Count - 1].timestamp)
        $hours   = ($lastTs - $firstTs).TotalHours
        if ($hours -gt 0) {
            $velocityPerHour = [math]::Round(($satTrend[$satTrend.Count - 1] - $satTrend[0]) / $hours, 2)
        }
    } catch {}

    return @{
        stagnant          = $stagnant
        regression        = $regression
        entries           = $entries.Count
        satisfied_trend   = $satTrend
        velocity_per_hour = $velocityPerHour
        latest_satisfied  = $satTrend[$satTrend.Count - 1]
        latest_health     = if ($entries[$entries.Count - 1].health_score) { $entries[$entries.Count - 1].health_score } else { 0 }
    }
}

function Start-HealthVelocityMonitor {
    <#
    .SYNOPSIS
        Background job: checks health velocity every 120s, sends ntfy alerts on stagnation/regression.
        Writes velocity.json to .gsd/health/.
    #>
    param(
        [string]$GsdDir,
        [string]$NtfyTopic
    )

    Stop-HealthVelocityMonitor

    $script:VELOCITY_JOB = Start-Job -ScriptBlock {
        param($GsdDir, $Topic)

        $stagnantChecks = 0
        $monitorStart = Get-Date

        while ($true) {
            Start-Sleep -Seconds 120
            try {
                # Read last 5 entries from health-history.jsonl
                $histPath = Join-Path $GsdDir "health\health-history.jsonl"
                if (-not (Test-Path $histPath)) { continue }

                $lines = Get-Content $histPath -Tail 5
                if ($lines.Count -lt 2) { continue }

                $entries = @()
                foreach ($line in $lines) {
                    try { $entries += ($line | ConvertFrom-Json) } catch {}
                }
                if ($entries.Count -lt 2) { continue }

                $satTrend = @($entries | ForEach-Object {
                    if ($_.satisfied) { [int]$_.satisfied } elseif ($_.health_score) { [int]$_.health_score } else { 0 }
                })

                # Regression check
                $regression = $false
                for ($i = 1; $i -lt $satTrend.Count; $i++) {
                    if ($satTrend[$i] -lt $satTrend[$i - 1]) { $regression = $true; break }
                }

                # Stagnation check (last 3 same)
                $stagnant = $false
                if ($satTrend.Count -ge 3) {
                    $last3 = $satTrend[($satTrend.Count - 3)..($satTrend.Count - 1)]
                    if (($last3 | Sort-Object -Unique).Count -eq 1) { $stagnant = $true }
                }

                if ($stagnant) { $stagnantChecks++ } else { $stagnantChecks = 0 }

                # Velocity calc
                $velocityPerHour = 0
                try {
                    $firstTs = [datetime]::Parse($entries[0].timestamp)
                    $lastTs  = [datetime]::Parse($entries[$entries.Count - 1].timestamp)
                    $hours   = ($lastTs - $firstTs).TotalHours
                    if ($hours -gt 0) {
                        $velocityPerHour = [math]::Round(($satTrend[$satTrend.Count - 1] - $satTrend[0]) / $hours, 2)
                    }
                } catch {}

                $stagnantMinutes = $stagnantChecks * 2
                $latestSat = $satTrend[$satTrend.Count - 1]
                $latestHealth = if ($entries[$entries.Count - 1].health_score) { $entries[$entries.Count - 1].health_score } else { 0 }

                # Write velocity.json
                $velDir = Join-Path $GsdDir "health"
                if (-not (Test-Path $velDir)) { New-Item $velDir -ItemType Directory -Force | Out-Null }
                @{
                    last_check        = (Get-Date).ToUniversalTime().ToString("o")
                    satisfied_trend   = $satTrend
                    stagnant_minutes  = $stagnantMinutes
                    velocity_per_hour = $velocityPerHour
                    latest_satisfied  = $latestSat
                    latest_health     = $latestHealth
                    regression        = $regression
                } | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $velDir "velocity.json") -Encoding UTF8

                # Ntfy alerts
                if ($Topic) {
                    if ($regression) {
                        $headers = @{ "Title" = "REGRESSION: Health decreased"; "Priority" = "urgent"; "Tags" = "rotating_light" }
                        $body = "Health regressed to ${latestHealth}%. Satisfied: $latestSat. Trend: $($satTrend -join ' -> '). Immediate attention needed."
                        try { Invoke-RestMethod -Uri "https://ntfy.sh/$Topic" -Method Post -Headers $headers -Body $body -ErrorAction SilentlyContinue } catch {}
                    }
                    elseif ($stagnantChecks -ge 3) {
                        $headers = @{ "Title" = "Health stagnant"; "Priority" = "high"; "Tags" = "warning" }
                        $body = "Health stagnant at ${latestHealth}% for ${stagnantMinutes} minutes. Satisfied: $latestSat. Consider adjusting agent pool or batch size."
                        try { Invoke-RestMethod -Uri "https://ntfy.sh/$Topic" -Method Post -Headers $headers -Body $body -ErrorAction SilentlyContinue } catch {}
                        $stagnantChecks = 0  # Reset after alert to avoid spam
                    }
                }
            } catch {
                # Never let velocity monitor failure kill the loop
            }
        }
    } -ArgumentList $GsdDir, $NtfyTopic

    Write-Host "  Health velocity: monitoring every 120s (background)" -ForegroundColor DarkGray
}

function Stop-HealthVelocityMonitor {
    <#
    .SYNOPSIS
        Stops the health velocity background job if running.
    #>
    if ($script:VELOCITY_JOB) {
        Stop-Job -Job $script:VELOCITY_JOB -ErrorAction SilentlyContinue
        Remove-Job -Job $script:VELOCITY_JOB -Force -ErrorAction SilentlyContinue
        $script:VELOCITY_JOB = $null
    }
}
# -- end Health Velocity Monitor (Patch #44) --

'@

    Add-Content -Path $resPath -Value $functions -Encoding UTF8
    Write-Host "  [OK] Appended Test-HealthVelocity + Start/Stop-HealthVelocityMonitor to resilience.ps1" -ForegroundColor Green
}

# ── 2. Wire into convergence-loop.ps1 ──
$loopPath = Join-Path $GlobalDir "scripts\convergence-loop.ps1"
$loopContent = Get-Content $loopPath -Raw
$nl = [Environment]::NewLine

# 2a. Start monitor after engine status heartbeat
$startBlock = '# Start health velocity monitor (120s checks, ntfy alerts on stagnation/regression)' + $nl + 'if (Get-Command Start-HealthVelocityMonitor -ErrorAction SilentlyContinue) ' + '{' + $nl + '    Start-HealthVelocityMonitor -GsdDir $GsdDir -NtfyTopic $script:NTFY_TOPIC' + $nl + '}'
$stopLine = '    if (Get-Command Stop-HealthVelocityMonitor -ErrorAction SilentlyContinue) ' + '{ Stop-HealthVelocityMonitor }'
$stopAnchor = 'if (Get-Command Stop-EngineStatusHeartbeat -ErrorAction SilentlyContinue) ' + '{ Stop-EngineStatusHeartbeat }'

if ($loopContent.Contains('Start-HealthVelocityMonitor')) {
    Write-Host "  [SKIP] Velocity monitor already wired in convergence-loop.ps1" -ForegroundColor DarkGray
} else {
    $anchor = 'if (Get-Command Start-EngineStatusHeartbeat -ErrorAction SilentlyContinue) ' + '{'
    $anchorIdx = $loopContent.IndexOf($anchor)
    if ($anchorIdx -ge 0) {
        $blockEnd = $loopContent.IndexOf('}', $anchorIdx + $anchor.Length)
        if ($blockEnd -ge 0) {
            $loopContent = $loopContent.Insert($blockEnd + 1, $nl + $nl + $startBlock)
            $loopContent | Set-Content $loopPath -Encoding UTF8
            Write-Host "  [OK] Wired Start-HealthVelocityMonitor into convergence-loop.ps1" -ForegroundColor Green
        } else {
            Write-Host "  [WARN] Could not find block end after anchor" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  [WARN] Could not find anchor in convergence-loop.ps1 — manual wiring needed" -ForegroundColor Yellow
    }
}

# 2b. Stop monitor in finally block
$loopContent = Get-Content $loopPath -Raw
if ($loopContent.Contains('Stop-HealthVelocityMonitor')) {
    Write-Host "  [SKIP] Stop-HealthVelocityMonitor already in finally block" -ForegroundColor DarkGray
} else {
    if ($loopContent.Contains($stopAnchor)) {
        $loopContent = $loopContent.Replace($stopAnchor, $stopAnchor + $nl + $stopLine)
        $loopContent | Set-Content $loopPath -Encoding UTF8
        Write-Host "  [OK] Wired Stop-HealthVelocityMonitor into finally block" -ForegroundColor Green
    } else {
        Write-Host "  [WARN] Could not find Stop-EngineStatusHeartbeat anchor in finally block" -ForegroundColor Yellow
    }
}

Write-Host "`n=== Patch #44 complete ===" -ForegroundColor Green
