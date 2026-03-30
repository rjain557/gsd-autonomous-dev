<#
.SYNOPSIS
    GSD Pipeline Clarification System
.DESCRIPTION
    Collects questions that require human input, writes a user-friendly
    PIPELINE-CLARIFICATIONS.md report, and reads back answers on the next run.

    Categories:
      rbac        - Which roles should access which routes
      auth_flow   - Auth model design decisions (storage, refresh strategy)
      todo_stub   - Unimplemented feature stubs (what should they do)
      dup_route   - Duplicate route paths (which to keep)
      env_config  - Environment variables / configuration values

    Usage:
      # In any pipeline script:
      . (Join-Path $modulesDir "clarification-system.ps1")

      # Collect a question
      Add-Clarification -Id "rbac_001" -Category "rbac" -Phase "RBAC-MATRIX" `
          -Context "UsersController DELETE has no [Authorize]" `
          -Question "Should DELETE /api/users/{id} be Admin-only, any authenticated user, or public?" `
          -File "Controllers/UsersController.cs" -Default "any authenticated user"

      # Check if there are pending questions
      $pending = Get-PendingClarifications

      # Write the human-readable report
      Write-ClarificationReport -OutputPath "PIPELINE-CLARIFICATIONS.md" -RepoName "my-repo"

      # On next run, load answers
      $answers = Read-ClarificationAnswers -FilePath "PIPELINE-CLARIFICATIONS.md"

      # Get answers as prompt context
      $ctx = Get-ClarificationsContext -Answers $answers -Category "rbac"
#>

# Module-level storage for this session
$script:clarificationList = [System.Collections.Generic.List[hashtable]]::new()
$script:clarificationIds  = [System.Collections.Generic.HashSet[string]]::new()

# ============================================================
# Add-Clarification
# ============================================================

function Add-Clarification {
    param(
        [Parameter(Mandatory)][string]$Id,
        [ValidateSet("rbac","auth_flow","todo_stub","dup_route","env_config","other")]
        [string]$Category = "other",
        [string]$Phase    = "",
        [string]$Context  = "",
        [Parameter(Mandatory)][string]$Question,
        [string]$File     = "",
        [string]$Default  = ""
    )
    if ($script:clarificationIds.Contains($Id)) { return }  # no duplicates
    $script:clarificationIds.Add($Id) | Out-Null
    $script:clarificationList.Add(@{
        id       = $Id
        category = $Category
        phase    = $Phase
        context  = $Context
        question = $Question
        file     = $File
        default  = $Default
        answer   = $null
    })
}

# ============================================================
# Get-PendingClarifications
# ============================================================

function Get-PendingClarifications {
    return @($script:clarificationList | Where-Object { $null -eq $_.answer })
}

function Get-AllClarifications {
    return @($script:clarificationList)
}

function Clear-Clarifications {
    $script:clarificationList.Clear()
    $script:clarificationIds.Clear()
}

# ============================================================
# Write-ClarificationReport
# ============================================================

function Write-ClarificationReport {
    param(
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$RepoName = "project",
        [string]$RerunCommand = ""
    )

    $pending = Get-PendingClarifications
    if ($pending.Count -eq 0) { return $false }

    # ---- JSON (machine-readable) ----
    $jsonPath = [System.IO.Path]::ChangeExtension($OutputPath, ".json")
    @{
        generated_at   = (Get-Date -Format "o")
        repo           = $RepoName
        status         = "pending"
        question_count = $pending.Count
        questions      = $pending
    } | ConvertTo-Json -Depth 10 | Set-Content $jsonPath -Encoding UTF8

    # ---- Markdown (human-readable) ----
    $rerunHint = if ($RerunCommand) { $RerunCommand } else { "re-run the pipeline (it will detect this file automatically)" }

    $md = [System.Text.StringBuilder]::new()
    $null = $md.AppendLine("# Pipeline Clarifications Required")
    $null = $md.AppendLine("")
    $null = $md.AppendLine("**Generated:** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  ")
    $null = $md.AppendLine("**Repo:** $RepoName  ")
    $null = $md.AppendLine("**Questions:** $($pending.Count)")
    $null = $md.AppendLine("")
    $null = $md.AppendLine("The pipeline paused because these items require your input.")
    $null = $md.AppendLine("Fill in each **ANSWER** line below, save this file, then $rerunHint.")
    $null = $md.AppendLine("")
    $null = $md.AppendLine("> **Format rules:**")
    $null = $md.AppendLine("> - Write your answer on the `ANSWER:` line (replace the placeholder)")
    $null = $md.AppendLine("> - You can write multiple lines — they will be joined")
    $null = $md.AppendLine("> - Leave `ANSWER: (required)` blank only if you want the pipeline to skip that issue")
    $null = $md.AppendLine("")
    $null = $md.AppendLine("---")
    $null = $md.AppendLine("")

    $categoryLabels = @{
        rbac       = "Role-Based Access Control (RBAC)"
        auth_flow  = "Authentication / Auth Flow Design"
        todo_stub  = "Unimplemented Feature Stubs"
        dup_route  = "Duplicate Routes"
        env_config = "Configuration / Environment Variables"
        other      = "Other"
    }

    $grouped = $pending | Group-Object { $_.category }
    $num = 1
    foreach ($group in $grouped) {
        $label = if ($categoryLabels.ContainsKey($group.Name)) { $categoryLabels[$group.Name] } else { $group.Name }
        $null = $md.AppendLine("## $label")
        $null = $md.AppendLine("")

        foreach ($q in $group.Group) {
            $null = $md.AppendLine("### Q$num — $($q.id)")
            if ($q.file) {
                $null = $md.AppendLine("**File:** ``$($q.file)``  ")
            }
            if ($q.phase) {
                $null = $md.AppendLine("**Phase:** $($q.phase)  ")
            }
            $null = $md.AppendLine("")
            if ($q.context) {
                $null = $md.AppendLine("**Context:** $($q.context)")
                $null = $md.AppendLine("")
            }
            $null = $md.AppendLine("**Question:** $($q.question)")
            $null = $md.AppendLine("")
            $defaultHint = if ($q.default) { " (default: $($q.default))" } else { " (required)" }
            $null = $md.AppendLine("ANSWER:$defaultHint")
            $null = $md.AppendLine("")
            $null = $md.AppendLine("---")
            $null = $md.AppendLine("")
            $num++
        }
    }

    $md.ToString() | Set-Content $OutputPath -Encoding UTF8
    return $true
}

# ============================================================
# Read-ClarificationAnswers
# ============================================================

function Read-ClarificationAnswers {
    param([string]$FilePath)

    $answers = @{}
    if (-not $FilePath -or -not (Test-Path $FilePath)) { return $answers }

    # Try JSON first (if user edited the JSON directly)
    $jsonPath = [System.IO.Path]::ChangeExtension($FilePath, ".json")
    if (Test-Path $jsonPath) {
        try {
            $data = Get-Content $jsonPath -Raw | ConvertFrom-Json
            foreach ($q in $data.questions) {
                if ($q.answer -and $q.answer -ne "" -and $q.answer -notmatch '^\(') {
                    $answers[$q.id] = $q.answer
                }
            }
            if ($answers.Count -gt 0) { return $answers }
        } catch { }
    }

    # Parse the Markdown file
    $content = Get-Content $FilePath -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return $answers }

    # Split on "### Q\d+" to get blocks
    $blocks = $content -split '(?m)^### Q\d+\s*—\s*'
    foreach ($block in $blocks) {
        if (-not $block.Trim()) { continue }

        # First line is the ID
        $lines  = $block -split "`n"
        $id     = $lines[0].Trim()
        if (-not $id) { continue }

        # Find ANSWER: line and collect text after it
        $answerLines = @()
        $inAnswer = $false
        foreach ($line in $lines) {
            if ($line -match '^ANSWER:\s*(.*)$') {
                $inAnswer = $true
                $inline = $Matches[1].Trim()
                if ($inline -and $inline -notmatch '^\(') { $answerLines += $inline }
                continue
            }
            if ($inAnswer) {
                if ($line -match '^---' -or $line -match '^## ' -or $line -match '^### ') { break }
                $trimmed = $line.Trim()
                if ($trimmed -and $trimmed -notmatch '^\(') { $answerLines += $trimmed }
            }
        }

        if ($answerLines.Count -gt 0) {
            $answers[$id] = ($answerLines -join " ").Trim()
        }
    }

    return $answers
}

# ============================================================
# Apply-ClarificationAnswers — merge loaded answers into list
# ============================================================

function Apply-ClarificationAnswers {
    param([hashtable]$Answers)
    if (-not $Answers -or $Answers.Count -eq 0) { return }
    for ($i = 0; $i -lt $script:clarificationList.Count; $i++) {
        $q = $script:clarificationList[$i]
        if ($Answers.ContainsKey($q.id)) {
            $q.answer = $Answers[$q.id]
        } elseif ($q.default -and $q.default -ne "") {
            # Apply default if no answer but default exists
            $q.answer = "[default] $($q.default)"
        }
    }
}

# ============================================================
# Get-ClarificationsContext — format answers as prompt context
# ============================================================

function Get-ClarificationsContext {
    param(
        [hashtable]$Answers,
        [string]$Category = ""
    )

    if (-not $Answers -or $Answers.Count -eq 0) { return "" }

    $relevant = if ($Category) {
        @($script:clarificationList | Where-Object { $_.category -eq $Category -and $Answers.ContainsKey($_.id) })
    } else {
        @($script:clarificationList | Where-Object { $Answers.ContainsKey($_.id) })
    }

    if ($relevant.Count -eq 0) { return "" }

    $lines = @("## User Clarifications (apply these decisions when generating or fixing code)")
    foreach ($q in $relevant) {
        $lines += "- **$($q.question)**"
        $lines += "  Answer: $($Answers[$q.id])"
    }
    return $lines -join "`n"
}
