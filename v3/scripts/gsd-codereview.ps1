<#
.SYNOPSIS
    GSD V3 Post-Convergence Code Review - Multi-model review against traceability matrix
.DESCRIPTION
    Uses 3 models (Claude, Codex, Gemini) to review satisfied requirements against
    actual code evidence from the traceability matrix. Produces a structured report
    with issues by severity, model, and interface.

    Usage:
      pwsh -File gsd-codereview.ps1 -RepoRoot "C:\repos\project"
      pwsh -File gsd-codereview.ps1 -RepoRoot "C:\repos\project" -Models "claude,codex"
      pwsh -File gsd-codereview.ps1 -RepoRoot "C:\repos\project" -MaxReqs 20 -Severity critical
      pwsh -File gsd-codereview.ps1 -RepoRoot "C:\repos\project" -OutputFormat markdown
.PARAMETER RepoRoot
    Repository root path (mandatory)
.PARAMETER Models
    Comma-separated models to use: claude, codex, gemini (default: "claude,codex,gemini")
.PARAMETER MaxReqs
    Maximum number of satisfied requirements to review per run (default: 50)
.PARAMETER Severity
    Filter output by severity: critical, high, medium, low, all (default: "all")
.PARAMETER OutputFormat
    Output format: json or markdown (default: "json")
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [string]$Models = "claude,codex,gemini",
    [int]$MaxReqs = 50,
    [ValidateSet("critical","high","medium","low","all")]
    [string]$Severity = "all",
    [ValidateSet("json","markdown")]
    [string]$OutputFormat = "json"
)

$ErrorActionPreference = "Continue"

# ============================================================
# SETUP: Resolve paths, load modules, load config
# ============================================================

$v3Dir = Split-Path $PSScriptRoot -Parent
$RepoRoot = (Resolve-Path $RepoRoot).Path
$GsdDir = Join-Path $RepoRoot ".gsd"

# Centralized logging
$repoName = Split-Path $RepoRoot -Leaf
$globalLogDir = Join-Path $env:USERPROFILE ".gsd-global/logs/$repoName"
if (-not (Test-Path $globalLogDir)) { New-Item -ItemType Directory -Path $globalLogDir -Force | Out-Null }

$timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$logFile = Join-Path $globalLogDir "codereview-$timestamp.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $entry = "$(Get-Date -Format 'HH:mm:ss') [$Level] $Message"
    Add-Content $logFile -Value $entry -Encoding UTF8 -ErrorAction SilentlyContinue
    $color = switch ($Level) {
        "ERROR" { "Red" }
        "WARN"  { "Yellow" }
        "OK"    { "Green" }
        "SKIP"  { "DarkGray" }
        default { "White" }
    }
    Write-Host "  $entry" -ForegroundColor $color
}

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  GSD V3 - Post-Convergence Code Review" -ForegroundColor Cyan
Write-Host "  Repo: $RepoRoot" -ForegroundColor DarkGray
Write-Host "  Models: $Models" -ForegroundColor DarkGray
Write-Host "  MaxReqs: $MaxReqs | Severity: $Severity | Format: $OutputFormat" -ForegroundColor DarkGray
Write-Host "  Log: $logFile" -ForegroundColor DarkGray
Write-Host "============================================" -ForegroundColor Cyan

# Load modules
$modulesDir = Join-Path $v3Dir "lib/modules"
$apiClientPath = Join-Path $modulesDir "api-client.ps1"
if (-not (Test-Path $apiClientPath)) {
    Write-Host "  [FATAL] api-client.ps1 not found at $apiClientPath" -ForegroundColor Red
    exit 1
}
. $apiClientPath

$costTrackerPath = Join-Path $modulesDir "cost-tracker.ps1"
if (Test-Path $costTrackerPath) { . $costTrackerPath }

# Load config
$configPath = Join-Path $v3Dir "config/global-config.json"
if (Test-Path $configPath) {
    $Config = Get-Content $configPath -Raw | ConvertFrom-Json
}

# Initialize cost tracking
if (Get-Command Initialize-CostTracker -ErrorAction SilentlyContinue) {
    Initialize-CostTracker -Mode "code_review" -BudgetCap 10.0 -GsdDir $GsdDir
}

# Parse model list
$selectedModels = @($Models -split ',' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ -in @("claude","codex","gemini") })
if ($selectedModels.Count -eq 0) {
    Write-Host "  [FATAL] No valid models specified. Use: claude, codex, gemini" -ForegroundColor Red
    exit 1
}
Write-Log "Selected models: $($selectedModels -join ', ')"

# ============================================================
# STEP 1: Load traceability matrix
# ============================================================

$traceabilityPath = Join-Path $GsdDir "compliance/traceability-matrix.json"
if (-not (Test-Path $traceabilityPath)) {
    Write-Log "Traceability matrix not found at $traceabilityPath" "ERROR"
    Write-Host "  [FATAL] Run the pipeline to convergence first to generate traceability matrix." -ForegroundColor Red
    exit 1
}

$traceability = Get-Content $traceabilityPath -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Log "Loaded traceability matrix: $($traceability.entries.Count) entries" "OK"

# ============================================================
# STEP 2: Load requirements matrix
# ============================================================

$matrixPath = Join-Path $GsdDir "requirements/requirements-matrix.json"
if (-not (Test-Path $matrixPath)) {
    Write-Log "Requirements matrix not found at $matrixPath" "ERROR"
    Write-Host "  [FATAL] No requirements matrix found. Run gsd-blueprint or gsd-existing first." -ForegroundColor Red
    exit 1
}

$matrix = Get-Content $matrixPath -Raw -Encoding UTF8 | ConvertFrom-Json
$totalReqs = $matrix.requirements.Count
$satisfiedReqs = @($matrix.requirements | Where-Object { $_.status -eq "satisfied" })
Write-Log "Requirements matrix: $totalReqs total, $($satisfiedReqs.Count) satisfied" "OK"

if ($satisfiedReqs.Count -eq 0) {
    Write-Log "No satisfied requirements to review" "WARN"
    Write-Host "  [DONE] Nothing to review." -ForegroundColor Yellow
    exit 0
}

# Cap at MaxReqs
$reviewBatch = $satisfiedReqs | Select-Object -First $MaxReqs
Write-Log "Reviewing $($reviewBatch.Count) of $($satisfiedReqs.Count) satisfied requirements"

# ============================================================
# STEP 3: Build traceability lookup (req_id -> evidence files)
# ============================================================

$traceMap = @{}
foreach ($entry in $traceability.entries) {
    $reqId = $entry.requirement_id
    if (-not $reqId) { $reqId = $entry.req_id }
    if (-not $reqId) { continue }
    $files = @()
    if ($entry.evidence_files) { $files += @($entry.evidence_files) }
    if ($entry.source_files) { $files += @($entry.source_files) }
    if ($entry.files) { $files += @($entry.files) }
    if ($entry.target_files) { $files += @($entry.target_files) }
    $traceMap[$reqId] = @($files | Select-Object -Unique)
}
Write-Log "Traceability lookup built: $($traceMap.Count) requirement mappings"

# ============================================================
# STEP 4: Review prompt
# ============================================================

$reviewSystemPrompt = @"
You are a senior code reviewer performing a post-convergence quality audit.
You review code against specific requirements to find issues the automated pipeline may have missed.

For each requirement + code pair, identify issues with severity levels:
- critical: Security vulnerability, data loss risk, compliance violation, broken core functionality
- high: Logic error, missing validation, incomplete implementation, performance problem
- medium: Code smell, missing error handling, weak typing, incomplete edge cases
- low: Style issue, naming convention, minor optimization opportunity, missing comments

Output ONLY valid JSON in this format:
{
  "issues": [
    {
      "severity": "critical|high|medium|low",
      "issue": "Brief description of the problem",
      "suggestion": "How to fix it"
    }
  ]
}

If the code fully satisfies the requirement with no issues, return: {"issues": []}
"@

# ============================================================
# STEP 5: Review each requirement with each model
# ============================================================

$allIssues = @()
$reviewedCount = 0
$skippedCount = 0
$errorCount = 0

Write-Host "`n--- Reviewing $($reviewBatch.Count) requirements with $($selectedModels.Count) model(s) ---" -ForegroundColor Yellow

foreach ($req in $reviewBatch) {
    $reqId = $req.id
    $reqText = $req.text
    $category = if ($req.category) { $req.category } else { "unknown" }

    # Get evidence files from traceability
    $evidenceFiles = @()
    if ($traceMap.ContainsKey($reqId)) {
        $evidenceFiles = $traceMap[$reqId]
    }
    # Fallback: use target_files from the requirement itself
    if ($evidenceFiles.Count -eq 0 -and $req.target_files) {
        $evidenceFiles = @($req.target_files)
    }

    if ($evidenceFiles.Count -eq 0) {
        Write-Log "$reqId - No evidence files found, skipping" "SKIP"
        $skippedCount++
        continue
    }

    # Read the first evidence file (truncate to 8K chars)
    $codeContent = ""
    $reviewedFile = ""
    foreach ($ef in $evidenceFiles) {
        $fullPath = if ([System.IO.Path]::IsPathRooted($ef)) { $ef } else { Join-Path $RepoRoot $ef }
        if (Test-Path $fullPath) {
            $rawContent = Get-Content $fullPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($rawContent) {
                $reviewedFile = $ef
                if ($rawContent.Length -gt 8000) {
                    $codeContent = $rawContent.Substring(0, 8000) + "`n// ... (truncated at 8K chars, full file: $($rawContent.Length) chars)"
                } else {
                    $codeContent = $rawContent
                }
                break
            }
        }
    }

    if (-not $codeContent) {
        Write-Log "$reqId - Evidence files not readable: $($evidenceFiles[0])" "SKIP"
        $skippedCount++
        continue
    }

    $reviewedCount++
    Write-Host "  [$reviewedCount/$($reviewBatch.Count)] $reqId - $reviewedFile" -ForegroundColor DarkGray

    # Build the review prompt
    $userPrompt = @"
## Requirement
ID: $reqId
Category: $category
Description: $reqText

## Evidence File
Path: $reviewedFile

## Code
$codeContent

## Task
Does this code fully satisfy the requirement above? Identify any issues with severity.
Return ONLY the JSON object with issues array.
"@

    # Send to each selected model
    foreach ($model in $selectedModels) {
        try {
            $result = $null
            $phase = "code-review-$model"

            switch ($model) {
                "claude" {
                    $result = Invoke-SonnetApi -SystemPrompt $reviewSystemPrompt -UserMessage $userPrompt -MaxTokens 2048 -JsonMode -Phase $phase
                }
                "codex" {
                    $result = Invoke-CodexMiniApi -SystemPrompt $reviewSystemPrompt -UserMessage $userPrompt -MaxTokens 2048 -Phase $phase
                }
                "gemini" {
                    $result = Invoke-GeminiApi -SystemPrompt $reviewSystemPrompt -UserMessage $userPrompt -MaxTokens 2048 -Phase $phase
                }
            }

            if ($result -and $result.Success -and $result.Text) {
                # Track cost
                if ($result.Usage -and (Get-Command Add-ApiCallCost -ErrorAction SilentlyContinue)) {
                    $modelId = switch ($model) {
                        "claude" { "claude-sonnet-4-6" }
                        "codex"  { "gpt-5.1-codex-mini" }
                        "gemini" { "gemini-2.5-flash" }
                    }
                    Add-ApiCallCost -Model $modelId -Usage $result.Usage -Phase $phase
                }

                # Parse JSON from response (strip markdown fences if present)
                $responseText = $result.Text.Trim()
                $responseText = $responseText -replace '(?s)^```(?:json)?\s*\n', '' -replace '\n```\s*$', ''

                try {
                    $parsed = $responseText | ConvertFrom-Json
                    $issues = @()
                    if ($parsed.issues) { $issues = @($parsed.issues) }

                    foreach ($issue in $issues) {
                        $sev = if ($issue.severity) { $issue.severity.ToLower() } else { "medium" }
                        # Apply severity filter
                        if ($Severity -ne "all" -and $sev -ne $Severity) { continue }

                        $allIssues += @{
                            requirement_id = $reqId
                            file           = $reviewedFile
                            model          = $model
                            severity       = $sev
                            category       = $category
                            issue          = if ($issue.issue) { "$($issue.issue)" } else { "Unspecified issue" }
                            suggestion     = if ($issue.suggestion) { "$($issue.suggestion)" } else { "" }
                        }
                    }

                    if ($issues.Count -gt 0) {
                        Write-Log "$reqId [$model]: $($issues.Count) issue(s) found" "WARN"
                    }
                }
                catch {
                    Write-Log "$reqId [$model]: Failed to parse response JSON - $($_.Exception.Message)" "WARN"
                    $errorCount++
                }
            }
            else {
                $errMsg = if ($result.Error) { $result.Error } elseif ($result.Message) { $result.Message } else { "Unknown error" }
                Write-Log "$reqId [$model]: API call failed - $errMsg" "ERROR"
                $errorCount++
            }
        }
        catch {
            Write-Log "$reqId [$model]: Exception - $($_.Exception.Message)" "ERROR"
            $errorCount++
        }
    }
}

# ============================================================
# STEP 6: Aggregate and build report
# ============================================================

Write-Host "`n--- Building Report ---" -ForegroundColor Yellow

$bySeverity = @{
    critical = @($allIssues | Where-Object { $_.severity -eq "critical" }).Count
    high     = @($allIssues | Where-Object { $_.severity -eq "high" }).Count
    medium   = @($allIssues | Where-Object { $_.severity -eq "medium" }).Count
    low      = @($allIssues | Where-Object { $_.severity -eq "low" }).Count
}

$byModel = @{}
foreach ($m in $selectedModels) {
    $byModel[$m] = @($allIssues | Where-Object { $_.model -eq $m }).Count
}

$byCategory = @{}
foreach ($issue in $allIssues) {
    $cat = if ($issue.category) { $issue.category } else { "unknown" }
    if (-not $byCategory.ContainsKey($cat)) { $byCategory[$cat] = 0 }
    $byCategory[$cat]++
}

# Build structured report
$report = @{
    generated_at          = (Get-Date -Format "o")
    repo                  = $RepoRoot
    models_used           = $selectedModels
    requirements_reviewed = $reviewedCount
    requirements_skipped  = $skippedCount
    api_errors            = $errorCount
    total_issues          = $allIssues.Count
    by_severity           = $bySeverity
    by_model              = $byModel
    by_category           = $byCategory
    issues                = $allIssues
}

# ============================================================
# STEP 7: Write report files
# ============================================================

$reviewDir = Join-Path $GsdDir "code-review"
if (-not (Test-Path $reviewDir)) { New-Item -ItemType Directory -Path $reviewDir -Force | Out-Null }

# JSON report
$reportPath = Join-Path $reviewDir "review-report.json"
$report | ConvertTo-Json -Depth 10 | Set-Content $reportPath -Encoding UTF8
Write-Log "Report saved: $reportPath" "OK"

# Human-readable markdown summary
$summaryPath = Join-Path $reviewDir "review-summary.md"
$summaryLines = @()
$summaryLines += "# Code Review Report"
$summaryLines += ""
$summaryLines += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$summaryLines += "Repo: ``$repoName``"
$summaryLines += "Models: $($selectedModels -join ', ')"
$summaryLines += ""
$summaryLines += "## Summary"
$summaryLines += ""
$summaryLines += "| Metric | Value |"
$summaryLines += "|--------|-------|"
$summaryLines += "| Requirements reviewed | $reviewedCount |"
$summaryLines += "| Requirements skipped | $skippedCount |"
$summaryLines += "| Total issues | $($allIssues.Count) |"
$summaryLines += "| API errors | $errorCount |"
$summaryLines += ""
$summaryLines += "## Issues by Severity"
$summaryLines += ""
$summaryLines += "| Severity | Count |"
$summaryLines += "|----------|-------|"
$summaryLines += "| Critical | $($bySeverity.critical) |"
$summaryLines += "| High | $($bySeverity.high) |"
$summaryLines += "| Medium | $($bySeverity.medium) |"
$summaryLines += "| Low | $($bySeverity.low) |"
$summaryLines += ""
$summaryLines += "## Issues by Model"
$summaryLines += ""
$summaryLines += "| Model | Count |"
$summaryLines += "|-------|-------|"
foreach ($m in $selectedModels) {
    $summaryLines += "| $m | $($byModel[$m]) |"
}
$summaryLines += ""
$summaryLines += "## Issues by Category"
$summaryLines += ""
$summaryLines += "| Category | Count |"
$summaryLines += "|----------|-------|"
foreach ($cat in ($byCategory.Keys | Sort-Object)) {
    $summaryLines += "| $cat | $($byCategory[$cat]) |"
}

# List critical and high issues
$criticalHigh = @($allIssues | Where-Object { $_.severity -in @("critical","high") })
if ($criticalHigh.Count -gt 0) {
    $summaryLines += ""
    $summaryLines += "## Critical & High Issues"
    $summaryLines += ""
    foreach ($issue in $criticalHigh) {
        $summaryLines += "### $($issue.requirement_id) [$($issue.severity)] ($($issue.model))"
        $summaryLines += "- **File**: ``$($issue.file)``"
        $summaryLines += "- **Issue**: $($issue.issue)"
        if ($issue.suggestion) {
            $summaryLines += "- **Fix**: $($issue.suggestion)"
        }
        $summaryLines += ""
    }
}

# Remaining medium/low as compact list
$mediumLow = @($allIssues | Where-Object { $_.severity -in @("medium","low") })
if ($mediumLow.Count -gt 0) {
    $summaryLines += ""
    $summaryLines += "## Medium & Low Issues"
    $summaryLines += ""
    $summaryLines += "| Req | Severity | Model | File | Issue |"
    $summaryLines += "|-----|----------|-------|------|-------|"
    foreach ($issue in $mediumLow) {
        $shortIssue = if ($issue.issue.Length -gt 80) { $issue.issue.Substring(0,77) + "..." } else { $issue.issue }
        $shortFile = Split-Path $issue.file -Leaf
        $summaryLines += "| $($issue.requirement_id) | $($issue.severity) | $($issue.model) | $shortFile | $shortIssue |"
    }
}

$summaryLines -join "`n" | Set-Content $summaryPath -Encoding UTF8
Write-Log "Summary saved: $summaryPath" "OK"

# ============================================================
# STEP 8: Print summary stats
# ============================================================

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  CODE REVIEW COMPLETE" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Requirements reviewed:  $reviewedCount" -ForegroundColor White
Write-Host "  Requirements skipped:   $skippedCount" -ForegroundColor DarkGray
Write-Host "  Total issues found:     $($allIssues.Count)" -ForegroundColor $(if ($allIssues.Count -eq 0) { "Green" } else { "Yellow" })

$critColor = if ($bySeverity.critical -gt 0) { "Red" } else { "Green" }
$highColor = if ($bySeverity.high -gt 0) { "Yellow" } else { "Green" }
Write-Host "    Critical: $($bySeverity.critical)" -ForegroundColor $critColor
Write-Host "    High:     $($bySeverity.high)" -ForegroundColor $highColor
Write-Host "    Medium:   $($bySeverity.medium)" -ForegroundColor White
Write-Host "    Low:      $($bySeverity.low)" -ForegroundColor DarkGray

Write-Host "  By model:" -ForegroundColor White
foreach ($m in $selectedModels) {
    Write-Host "    ${m}: $($byModel[$m])" -ForegroundColor DarkGray
}

Write-Host "  By category:" -ForegroundColor White
foreach ($cat in ($byCategory.Keys | Sort-Object)) {
    Write-Host "    ${cat}: $($byCategory[$cat])" -ForegroundColor DarkGray
}

Write-Host "  API errors: $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { "Yellow" } else { "DarkGray" })
Write-Host "`n  Report:  $reportPath" -ForegroundColor DarkGray
Write-Host "  Summary: $summaryPath" -ForegroundColor DarkGray

if (Get-Command Get-TotalCost -ErrorAction SilentlyContinue) {
    Write-Host "  Cost:    `$$(Get-TotalCost)" -ForegroundColor DarkGray
}

Write-Host "============================================`n" -ForegroundColor Cyan

# Return exit code: 0 if no critical issues, 1 if critical issues found
exit $(if ($bySeverity.critical -gt 0) { 1 } else { 0 })
