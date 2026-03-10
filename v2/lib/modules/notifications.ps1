# ===============================================================
# GSD v2.0 Notifications - Extracted from convergence-loop.ps1
# ntfy.sh push notifications, heartbeat, command listener
# ===============================================================

$script:NtfyTopic = $null
$script:HeartbeatJob = $null
$script:ListenerJob = $null
$script:PipelineStartTime = $null

function Initialize-Notifications {
    <#
    .SYNOPSIS
        Set up notification topic and start background heartbeat.
    .PARAMETER Topic
        Explicit ntfy topic, or "auto" to derive from username + repo name.
    .PARAMETER RepoRoot
        Project root for auto-topic derivation.
    #>
    param(
        [string]$Topic = "auto",
        [string]$RepoRoot
    )

    $script:PipelineStartTime = Get-Date

    if ($Topic -eq "auto") {
        $username = if ($env:USERNAME) { $env:USERNAME } else { $env:USER }
        $repoName = Split-Path $RepoRoot -Leaf

        # Sanitize: lowercase, special chars -> hyphens
        $safeName = ($repoName -replace '[^a-zA-Z0-9-]', '-').ToLower().Trim('-')
        $safeUser = ($username -replace '[^a-zA-Z0-9-]', '-').ToLower().Trim('-')
        $script:NtfyTopic = "gsd-$safeUser-$safeName"
    } else {
        $script:NtfyTopic = $Topic
    }

    Write-Host "  Notifications: ntfy.sh topic = $($script:NtfyTopic)" -ForegroundColor DarkGray
    Write-Host "  Subscribe: https://ntfy.sh/$($script:NtfyTopic)" -ForegroundColor DarkGray
}

function Send-GsdNotification {
    <#
    .SYNOPSIS
        Send a notification via ntfy.sh.
    #>
    param(
        [string]$Title,
        [string]$Message,
        [string]$Tags = "",
        [string]$Priority = "default"
    )

    if (-not $script:NtfyTopic) { return }

    try {
        $headers = @{
            "Title"    = $Title
            "Priority" = $Priority
        }
        if ($Tags) { $headers["Tags"] = $Tags }

        Invoke-RestMethod -Uri "https://ntfy.sh/$($script:NtfyTopic)" `
            -Method Post -Body $Message -Headers $headers `
            -TimeoutSec 10 -ErrorAction SilentlyContinue | Out-Null
    } catch {
        # Silently ignore notification failures
    }
}

function Send-StepNotification {
    <#
    .SYNOPSIS
        Send a step-completion notification with standard format.
    #>
    param(
        [string]$StepId,
        [string]$Status,
        [string]$Details = ""
    )

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

    Send-GsdNotification -Title "GSD v2: $StepId" -Message $msg -Tags $emoji
}

function Send-IterationNotification {
    <#
    .SYNOPSIS
        Send iteration progress notification.
    #>
    param(
        [int]$Iteration,
        [int]$TotalIterations,
        [string]$Status,
        [int]$PassedReqs = 0,
        [int]$FailedReqs = 0,
        [string]$Details = ""
    )

    $elapsed = if ($script:PipelineStartTime) {
        [math]::Round(((Get-Date) - $script:PipelineStartTime).TotalMinutes, 1)
    } else { 0 }

    $msg = "Iteration $Iteration/$TotalIterations`nPassed: $PassedReqs | Failed: $FailedReqs`nElapsed: ${elapsed}m"
    if ($Details) { $msg += "`n$Details" }

    $priority = if ($Status -eq "failed") { "high" } else { "default" }
    $tags = if ($Status -eq "complete") { "chart_with_upwards_trend" } else { "warning" }

    Send-GsdNotification -Title "GSD v2: Iteration $Iteration" -Message $msg -Tags $tags -Priority $priority
}

function Send-ConvergedNotification {
    <#
    .SYNOPSIS
        Send final convergence notification with cost summary.
    #>
    param(
        [int]$TotalIterations,
        [int]$TotalRequirements,
        [string]$CostSummary = ""
    )

    $elapsed = if ($script:PipelineStartTime) {
        [math]::Round(((Get-Date) - $script:PipelineStartTime).TotalMinutes, 1)
    } else { 0 }

    $msg = "ALL REQUIREMENTS SATISFIED!`nIterations: $TotalIterations`nRequirements: $TotalRequirements`nTotal time: ${elapsed}m"
    if ($CostSummary) { $msg += "`n$CostSummary" }

    Send-GsdNotification -Title "GSD v2: CONVERGED!" -Message $msg -Tags "tada,white_check_mark" -Priority "high"
}

function Send-EscalationNotification {
    <#
    .SYNOPSIS
        Send urgent escalation notification when human intervention needed.
    #>
    param(
        [string]$Reason,
        [string]$Details = ""
    )

    $msg = "HUMAN INTERVENTION NEEDED`nReason: $Reason"
    if ($Details) { $msg += "`n$Details" }

    Send-GsdNotification -Title "GSD v2: NEEDS HUMAN" -Message $msg -Tags "sos" -Priority "urgent"
}

function Start-HeartbeatMonitor {
    <#
    .SYNOPSIS
        Start background heartbeat that sends status every N minutes.
    .PARAMETER IntervalMinutes
        Minutes between heartbeats (default: 10)
    .PARAMETER GetStatusFunc
        ScriptBlock that returns current status hashtable
    #>
    param(
        [int]$IntervalMinutes = 10,
        [scriptblock]$GetStatusFunc
    )

    if (-not $script:NtfyTopic) { return }

    $script:HeartbeatJob = Start-Job -ScriptBlock {
        param($Topic, $IntervalMs, $StatusFunc)

        while ($true) {
            Start-Sleep -Milliseconds $IntervalMs
            try {
                $headers = @{
                    "Title"    = "GSD v2: Heartbeat"
                    "Priority" = "low"
                    "Tags"     = "hourglass_flowing_sand"
                }
                $msg = "[GSD-STATUS] Pipeline running | $(Get-Date -Format 'HH:mm')"
                Invoke-RestMethod -Uri "https://ntfy.sh/$Topic" `
                    -Method Post -Body $msg -Headers $headers `
                    -TimeoutSec 10 -ErrorAction SilentlyContinue | Out-Null
            } catch { }
        }
    } -ArgumentList $script:NtfyTopic, ($IntervalMinutes * 60 * 1000), $GetStatusFunc
}

function Start-CommandListener {
    <#
    .SYNOPSIS
        Start background listener that responds to "progress" commands via ntfy.
    .PARAMETER GetProgressFunc
        ScriptBlock that returns formatted progress string
    #>
    param(
        [scriptblock]$GetProgressFunc
    )

    if (-not $script:NtfyTopic) { return }

    # Command listener polls ntfy for incoming messages
    $script:ListenerJob = Start-Job -ScriptBlock {
        param($Topic)

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
                            if ($msg.message -and $msg.message.Trim().ToLower() -eq "progress" -and
                                $msg.message -notmatch "^\[GSD-STATUS\]") {
                                # Respond with progress
                                $headers = @{
                                    "Title" = "GSD v2: Progress"
                                    "Tags"  = "bar_chart"
                                }
                                Invoke-RestMethod -Uri "https://ntfy.sh/$Topic" `
                                    -Method Post -Body "[GSD-STATUS] Pipeline active | $(Get-Date -Format 'HH:mm')" `
                                    -Headers $headers -TimeoutSec 10 -ErrorAction SilentlyContinue | Out-Null
                            }
                            if ($msg.time) { $since = $msg.time + 1 }
                        } catch { }
                    }
                }
            } catch { }
        }
    } -ArgumentList $script:NtfyTopic
}

function Stop-BackgroundMonitors {
    <#
    .SYNOPSIS
        Stop heartbeat and command listener background jobs.
    #>
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

Write-Host "  Notifications module loaded" -ForegroundColor DarkGray
