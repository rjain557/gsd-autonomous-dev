<#
.SYNOPSIS
    GSD V3 Post-Convergence Code Review with Auto-Fix Loop
.DESCRIPTION
    Uses 3 models (Claude, Codex, Gemini) to review satisfied requirements against
    actual code evidence from the traceability matrix. When issues are found, uses
    a fix model (Codex by default) to generate and apply corrections, then re-reviews
    until clean or max cycles reached.

    Usage:
      pwsh -File gsd-codereview.ps1 -RepoRoot "C:\repos\project"
      pwsh -File gsd-codereview.ps1 -RepoRoot "C:\repos\project" -MaxCycles 5
      pwsh -File gsd-codereview.ps1 -RepoRoot "C:\repos\project" -Models "claude,codex" -FixModel "codex"
      pwsh -File gsd-codereview.ps1 -RepoRoot "C:\repos\project" -ReviewOnly
.PARAMETER RepoRoot
    Repository root path (mandatory)
.PARAMETER Models
    Comma-separated review models: claude, codex, gemini (default: "claude,codex,gemini")
.PARAMETER FixModel
    Model used for generating fixes: claude or codex (default: "claude")
.PARAMETER MaxReqs
    Maximum satisfied requirements to review per run (default: 50)
.PARAMETER MaxCycles
    Maximum review-fix cycles before stopping (default: 5)
.PARAMETER MinSeverityToFix
    Minimum severity to auto-fix: critical, high, medium, low (default: "medium")
.PARAMETER ReviewOnly
    Skip auto-fix, just review (original behavior)
.PARAMETER Severity
    Filter output by severity: critical, high, medium, low, all (default: "all")
.PARAMETER OutputFormat
    Output format: json or markdown (default: "json")
.PARAMETER RunSmokeTest
    After code review completes, automatically run gsd-smoketest.ps1 for integration validation
.PARAMETER ConnectionString
    SQL Server connection string passed to smoke test for live DB validation (optional)
.PARAMETER TestUsers
    JSON array of test user credentials passed to smoke test (optional)
.PARAMETER AzureAdConfig
    JSON object with Azure AD configuration passed to smoke test (optional)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [string]$Models = "claude,codex,gemini",
    [ValidateSet("claude","codex")]
    [string]$FixModel = "claude",
    [int]$MaxReqs = 50,
    [int]$MaxCycles = 5,
    [ValidateSet("critical","high","medium","low")]
    [string]$MinSeverityToFix = "medium",
    [switch]$ReviewOnly,
    [ValidateSet("critical","high","medium","low","all")]
    [string]$Severity = "all",
    [ValidateSet("json","markdown")]
    [string]$OutputFormat = "json",
    [int]$SkipReqs = 0,
    [switch]$RunSmokeTest,
    [string]$ConnectionString = "",
    [string]$TestUsers = "",
    [string]$AzureAdConfig = ""
)

$ErrorActionPreference = "Continue"

# Severity ordering for comparisons
$severityRank = @{ "critical" = 4; "high" = 3; "medium" = 2; "low" = 1 }
$minFixRank = $severityRank[$MinSeverityToFix]

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
        "FIX"   { "Magenta" }
        "CYCLE" { "Cyan" }
        default { "White" }
    }
    Write-Host "  $entry" -ForegroundColor $color
}

$modeLabel = if ($ReviewOnly) { "REVIEW ONLY" } else { "REVIEW + AUTO-FIX (max $MaxCycles cycles)" }
Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  GSD V3 - Code Review with Auto-Fix" -ForegroundColor Cyan
Write-Host "  Mode: $modeLabel" -ForegroundColor Cyan
Write-Host "  Repo: $RepoRoot" -ForegroundColor DarkGray
Write-Host "  Review models: $Models" -ForegroundColor DarkGray
if (-not $ReviewOnly) {
    Write-Host "  Fix model: $FixModel | Min severity to fix: $MinSeverityToFix" -ForegroundColor DarkGray
}
Write-Host "  MaxReqs: $MaxReqs | SkipReqs: $SkipReqs | Severity: $Severity | Format: $OutputFormat" -ForegroundColor DarkGray
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

$traceabilityUpdaterPath = Join-Path $modulesDir "traceability-updater.ps1"
if (Test-Path $traceabilityUpdaterPath) { . $traceabilityUpdaterPath }

# Load config
$configPath = Join-Path $v3Dir "config/global-config.json"
if (Test-Path $configPath) {
    $Config = Get-Content $configPath -Raw | ConvertFrom-Json
}

# Initialize cost tracking
if (Get-Command Initialize-CostTracker -ErrorAction SilentlyContinue) {
    Initialize-CostTracker -Mode "code_review" -BudgetCap 20.0 -GsdDir $GsdDir
}

# Parse model list
$selectedModels = @($Models -split ',' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ -in @("claude","codex","gemini") })
if ($selectedModels.Count -eq 0) {
    Write-Host "  [FATAL] No valid models specified. Use: claude, codex, gemini" -ForegroundColor Red
    exit 1
}
Write-Log "Selected review models: $($selectedModels -join ', ')"

# ============================================================
# STEP 1: Load traceability matrix
# ============================================================

$traceabilityPath = Join-Path $GsdDir "compliance/traceability-matrix.json"
$traceability = $null
if (Test-Path $traceabilityPath) {
    $traceability = Get-Content $traceabilityPath -Raw -Encoding UTF8 | ConvertFrom-Json
    # Handle both formats: .entries[] and .requirements[]
    $traceEntries = @()
    if ($traceability.entries) { $traceEntries = @($traceability.entries) }
    elseif ($traceability.requirements) { $traceEntries = @($traceability.requirements) }
    Write-Log "Loaded traceability matrix: $($traceEntries.Count) entries" "OK"
} else {
    Write-Log "Traceability matrix not found - will use requirement target_files as fallback" "WARN"
    $traceEntries = @()
}

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

# Cap at MaxReqs with optional offset
if ($SkipReqs -gt 0) {
    $reviewBatch = $satisfiedReqs | Select-Object -Skip $SkipReqs -First $MaxReqs
    Write-Log "Reviewing reqs $($SkipReqs + 1)-$($SkipReqs + $reviewBatch.Count) of $($satisfiedReqs.Count) satisfied requirements"
} else {
    $reviewBatch = $satisfiedReqs | Select-Object -First $MaxReqs
    Write-Log "Reviewing $($reviewBatch.Count) of $($satisfiedReqs.Count) satisfied requirements"
}

# ============================================================
# STEP 3: Build traceability lookup (req_id -> evidence files)
# ============================================================

$traceMap = @{}
foreach ($entry in $traceEntries) {
    $reqId = $entry.requirement_id
    if (-not $reqId) { $reqId = $entry.req_id }
    if (-not $reqId) { $reqId = $entry.id }
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
# STEP 4: Prompts
# ============================================================

$reviewSystemPrompt = @"
You are a code reviewer. Review code against a requirement. Respond with ONLY a JSON object. No markdown, no explanation, no preamble. Just the JSON object starting with { and ending with }.

Format: {"issues":[{"severity":"critical|high|medium|low","issue":"description","suggestion":"fix","line_range":"start-end or null"}]}

If no issues: {"issues":[]}

Severity: critical=security/data loss, high=logic/validation error, medium=code smell/missing error handling, low=style/naming.
Focus on real problems. Do NOT report issues about truncation or file length. Do NOT report style-only issues unless they affect correctness.
"@

$fixSystemPrompt = @"
You are a code fixer. You receive a source file and a list of issues found by code review. Your job is to fix ALL the issues and return the COMPLETE corrected file.

Rules:
1. Return ONLY the corrected file content. No markdown fences. No explanation. No preamble.
2. Fix every issue listed. Do not skip any.
3. Preserve the file's overall structure, imports, and exports.
4. Do not add unnecessary changes beyond what's needed to fix the issues.
5. If an issue mentions missing functionality, add a minimal correct implementation.
6. The output must be valid, compilable code in the same language as the input.
"@

# ============================================================
# HELPER: Read file content for a requirement
# ============================================================

function Get-ReqFileContent {
    param([object]$Req, [hashtable]$TraceMap, [string]$Root)

    $reqId = $Req.id
    if (-not $reqId) { $reqId = $Req.requirement_id }
    $evidenceFiles = @()
    if ($reqId -and $TraceMap.ContainsKey($reqId)) {
        $evidenceFiles = $TraceMap[$reqId]
    }
    # Fallback: use files from the requirement itself (various key names)
    if ($evidenceFiles.Count -eq 0 -and $Req.files) {
        $evidenceFiles = @($Req.files)
    }
    if ($evidenceFiles.Count -eq 0 -and $Req.target_files) {
        $evidenceFiles = @($Req.target_files)
    }
    if ($evidenceFiles.Count -eq 0) { return $null }

    # Read ALL evidence files (up to 16K each, max 3 files)
    $fileContents = @()
    $fileNames = @()
    $filePaths = @()
    $filesRead = 0
    foreach ($ef in $evidenceFiles) {
        if ($filesRead -ge 3) { break }
        $fullPath = if ([System.IO.Path]::IsPathRooted($ef)) { $ef } else { Join-Path $Root $ef }
        # If direct path doesn't exist, search for the filename in common subdirectories
        if (-not (Test-Path $fullPath)) {
            $fileName = [System.IO.Path]::GetFileName($ef)
            $searchDirs = @("src", "generated", "src/Client", "src/Server", "src/web", "db")
            foreach ($sd in $searchDirs) {
                $searchRoot = Join-Path $Root $sd
                if (Test-Path $searchRoot) {
                    $found = Get-ChildItem -Path $searchRoot -Filter $fileName -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($found) {
                        $fullPath = $found.FullName
                        break
                    }
                }
            }
        }
        if (Test-Path $fullPath) {
            $rawContent = Get-Content $fullPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($rawContent) {
                $truncated = $false
                if ($rawContent.Length -gt 32000) {
                    $rawContent = $rawContent.Substring(0, 32000)
                    $truncated = $true
                }
                $fileContents += @{
                    path = $ef
                    fullPath = $fullPath
                    content = $rawContent
                    truncated = $truncated
                }
                $fileNames += $ef
                $filePaths += $fullPath
                $filesRead++
            }
        }
    }

    if ($fileContents.Count -eq 0) { return $null }

    return @{
        files = $fileContents
        names = $fileNames
        paths = $filePaths
    }
}

# ============================================================
# HELPER: Review a single requirement with all models
# ============================================================

function Invoke-ReviewReq {
    param([object]$Req, [array]$FileData, [array]$Models)

    $reqId = $Req.id
    $reqText = $Req.text
    $category = if ($Req.category) { $Req.category } else { "unknown" }

    # Build code section from all evidence files
    $codeSection = ""
    foreach ($f in $FileData) {
        $truncNote = ""
        if ($f.truncated) { $truncNote = "`n[NOTE: This file was truncated at 32KB. Code beyond this point is NOT shown. Do NOT report issues about missing/incomplete code at the end of the file - only review what is visible.]`n" }
        $codeSection += "### File: $($f.path)$truncNote`n$($f.content)`n`n"
    }

    $userPrompt = @"
## Requirement
ID: $reqId
Category: $category
Description: $reqText

## Evidence Files
$codeSection

## Task
Does this code fully satisfy the requirement above? Identify any issues with severity.
Return ONLY the JSON object with issues array. Each issue must include line_range if applicable.
"@

    $issues = @()

    # --- Parallel review: launch all model calls as jobs simultaneously ---
    $jobs = @{}
    foreach ($model in $Models) {
        $phase = "code-review-$model"
        $jobScript = {
            param($model, $systemPrompt, $userPrompt, $maxTok, $phase, $apiClientPath, $configPath, $costTrackerPath)
            . $apiClientPath
            if (Test-Path $configPath) { $script:Config = Get-Content $configPath -Raw | ConvertFrom-Json }
            if ($costTrackerPath -and (Test-Path $costTrackerPath)) { . $costTrackerPath }
            switch ($model) {
                "claude"  { Invoke-SonnetApi -SystemPrompt $systemPrompt -UserMessage $userPrompt -MaxTokens $maxTok -JsonMode -Phase $phase }
                "codex"   { Invoke-CodexMiniApi -SystemPrompt $systemPrompt -UserMessage $userPrompt -MaxTokens 16384 -Phase $phase }
                "gemini"  { Invoke-GeminiApi -SystemPrompt $systemPrompt -UserMessage $userPrompt -MaxTokens $maxTok -Phase $phase }
            }
        }
        $maxTok = if ($model -eq "codex") { 16384 } else { 8192 }
        $jobs[$model] = Start-Job -ScriptBlock $jobScript -ArgumentList $model, $reviewSystemPrompt, $userPrompt, $maxTok, $phase, $apiClientPath, $configPath, $costTrackerPath
    }

    # Wait for all jobs (max 300s)
    $allJobs = @($jobs.Values)
    $null = $allJobs | Wait-Job -Timeout 300

    # Collect results
    foreach ($model in $Models) {
        $job = $jobs[$model]
        $phase = "code-review-$model"
        try {
            if ($job.State -eq 'Running') {
                $job | Stop-Job -PassThru | Remove-Job -Force
                Write-Log "$reqId [$model]: Timed out after 300s" "ERROR"
                $script:totalErrors++
                continue
            }
            $result = $job | Receive-Job
            $job | Remove-Job -Force -ErrorAction SilentlyContinue

            if ($result -and $result.Success -and $result.Text) {
                if ($result.Usage -and (Get-Command Add-ApiCallCost -ErrorAction SilentlyContinue)) {
                    $modelId = switch ($model) {
                        "claude" { "claude-sonnet-4-6" }
                        "codex"  { "gpt-5.1-codex-mini" }
                        "gemini" { "gemini-2.5-flash" }
                    }
                    Add-ApiCallCost -Model $modelId -Usage $result.Usage -Phase $phase
                }

                $responseText = $result.Text.Trim()
                $responseText = $responseText -replace '(?s)^```(?:json)?\s*\n', '' -replace '\n```\s*$', ''

                try {
                    $parsed = $responseText | ConvertFrom-Json
                    if ($parsed.issues) {
                        foreach ($issue in @($parsed.issues)) {
                            $sev = if ($issue.severity) { $issue.severity.ToLower() } else { "medium" }
                            if ($Severity -ne "all" -and $sev -ne $Severity) { continue }

                            $issues += @{
                                requirement_id = $reqId
                                file           = $FileData[0].path
                                full_path      = $FileData[0].fullPath
                                model          = $model
                                severity       = $sev
                                category       = $category
                                issue          = if ($issue.issue) { "$($issue.issue)" } else { "Unspecified issue" }
                                suggestion     = if ($issue.suggestion) { "$($issue.suggestion)" } else { "" }
                                line_range     = if ($issue.line_range) { "$($issue.line_range)" } else { "" }
                            }
                        }
                    }
                }
                catch {
                    Write-Log "$reqId [$model]: JSON parse failed - $($_.Exception.Message)" "WARN"
                    $script:totalErrors++
                }
            }
            else {
                $errMsg = if ($result.Error) { $result.Error } elseif ($result.Message) { $result.Message } else { "Unknown" }
                Write-Log "$reqId [$model]: API error - $errMsg" "ERROR"
                $script:totalErrors++
            }
        }
        catch {
            Write-Log "$reqId [$model]: Exception - $($_.Exception.Message)" "ERROR"
            $script:totalErrors++
            $job | Remove-Job -Force -ErrorAction SilentlyContinue
        }
    }

    return $issues
}

# ============================================================
# HELPER: Fix issues in a file using the fix model
# ============================================================

function Invoke-FixFile {
    param(
        [string]$FilePath,
        [string]$RelPath,
        [array]$Issues,
        [string]$Model
    )

    if (-not (Test-Path $FilePath)) {
        Write-Log "Fix skipped - file not found: $RelPath" "WARN"
        return $false
    }

    $fileContent = Get-Content $FilePath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not $fileContent) {
        Write-Log "Fix skipped - file empty or unreadable: $RelPath" "WARN"
        return $false
    }

    # Build issue list for the prompt
    $issueList = ""
    $idx = 1
    foreach ($issue in $Issues) {
        $issueList += "$idx. [$($issue.severity)] $($issue.issue)"
        if ($issue.suggestion) { $issueList += " -- Suggestion: $($issue.suggestion)" }
        if ($issue.line_range) { $issueList += " (lines $($issue.line_range))" }
        $issueList += "`n"
        $idx++
    }

    $fixPrompt = @"
## File to Fix
Path: $RelPath

## Current Code
$fileContent

## Issues to Fix
$issueList

## Task
Fix ALL issues listed above. Return the COMPLETE corrected file. No markdown fences. No explanation.
"@

    try {
        $result = $null
        $phase = "code-fix-$Model"

        switch ($Model) {
            "codex" {
                $result = Invoke-CodexMiniApi -SystemPrompt $fixSystemPrompt -UserMessage $fixPrompt -MaxTokens 16384 -Phase $phase
            }
            "claude" {
                $result = Invoke-SonnetApi -SystemPrompt $fixSystemPrompt -UserMessage $fixPrompt -MaxTokens 16384 -Phase $phase
            }
        }

        if ($result -and $result.Success -and $result.Text) {
            if ($result.Usage -and (Get-Command Add-ApiCallCost -ErrorAction SilentlyContinue)) {
                $modelId = switch ($Model) {
                    "codex"  { "gpt-5.1-codex-mini" }
                    "claude" { "claude-sonnet-4-6" }
                }
                Add-ApiCallCost -Model $modelId -Usage $result.Usage -Phase $phase
            }

            $fixedCode = $result.Text.Trim()
            # Strip markdown fences if model wraps output
            $fixedCode = $fixedCode -replace '(?s)^```[a-z]*\s*\n', '' -replace '\n```\s*$', ''

            # Sanity: fixed code should be at least 50% the length of original (prevent wipes)
            if ($fixedCode.Length -lt ($fileContent.Length * 0.5)) {
                Write-Log "Fix rejected - output too short ($($fixedCode.Length) vs $($fileContent.Length) chars): $RelPath" "WARN"
                return $false
            }

            # Sanity: fixed code should not be identical (no-op fix)
            if ($fixedCode -eq $fileContent) {
                Write-Log "Fix skipped - no changes produced for: $RelPath" "SKIP"
                return $false
            }

            # Write the fix
            $fixedCode | Set-Content $FilePath -Encoding UTF8 -NoNewline
            Write-Log "Fixed $($Issues.Count) issue(s) in: $RelPath" "FIX"
            return $true
        }
        else {
            $errMsg = if ($result.Error) { $result.Error } elseif ($result.Message) { $result.Message } else { "Unknown" }
            Write-Log "Fix API error for $RelPath : $errMsg" "ERROR"
            return $false
        }
    }
    catch {
        Write-Log "Fix exception for $RelPath : $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# ============================================================
# MAIN LOOP: Review -> Fix -> Re-review
# ============================================================

$script:totalErrors = 0
$cycleHistory = @()
$overallStartTime = Get-Date
$cleanReqIds = @{}  # Track reqs with 0 issues — skip on re-review

for ($cycle = 1; $cycle -le $MaxCycles; $cycle++) {
    $cycleStart = Get-Date

    Write-Host "`n" -NoNewline
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "  CYCLE $cycle / $MaxCycles" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan

    Write-Log "=== Starting review cycle $cycle ===" "CYCLE"

    # ---- REVIEW PHASE ----
    $allIssues = @()
    $reviewedCount = 0
    $skippedCount = 0

    Write-Host "`n--- Reviewing $($reviewBatch.Count) requirements with $($selectedModels.Count) model(s) ---" -ForegroundColor Yellow

    foreach ($req in $reviewBatch) {
        # Skip reqs that were clean in prior cycle (no issues found)
        if ($cycle -gt 1 -and $cleanReqIds.ContainsKey($req.id)) {
            $skippedCount++
            continue
        }

        $fileData = Get-ReqFileContent -Req $req -TraceMap $traceMap -Root $RepoRoot
        if (-not $fileData) {
            $skippedCount++
            continue
        }

        $reviewedCount++
        $primaryFile = $fileData.names[0]
        Write-Host "  [$reviewedCount/$($reviewBatch.Count)] $($req.id) - $primaryFile" -ForegroundColor DarkGray

        $reqIssues = Invoke-ReviewReq -Req $req -FileData $fileData.files -Models $selectedModels
        $allIssues += $reqIssues

        if ($reqIssues.Count -gt 0) {
            Write-Log "$($req.id): $($reqIssues.Count) issue(s) found" "WARN"
        } else {
            # Mark as clean so we skip it in future cycles
            $cleanReqIds[$req.id] = $true
        }
    }

    # ---- AGGREGATE ----
    $bySeverity = @{
        critical = @($allIssues | Where-Object { $_.severity -eq "critical" }).Count
        high     = @($allIssues | Where-Object { $_.severity -eq "high" }).Count
        medium   = @($allIssues | Where-Object { $_.severity -eq "medium" }).Count
        low      = @($allIssues | Where-Object { $_.severity -eq "low" }).Count
    }

    $critHighCount = $bySeverity.critical + $bySeverity.high
    $fixableCount = @($allIssues | Where-Object { $severityRank[$_.severity] -ge $minFixRank }).Count

    Write-Host "`n  Cycle $cycle results: $($allIssues.Count) issues (C:$($bySeverity.critical) H:$($bySeverity.high) M:$($bySeverity.medium) L:$($bySeverity.low))" -ForegroundColor $(if ($allIssues.Count -eq 0) { "Green" } else { "Yellow" })

    $cycleHistory += @{
        cycle = $cycle
        total_issues = $allIssues.Count
        critical = $bySeverity.critical
        high = $bySeverity.high
        medium = $bySeverity.medium
        low = $bySeverity.low
        reviewed = $reviewedCount
        skipped = $skippedCount
        fixable = $fixableCount
    }

    # ---- CHECK EXIT CONDITIONS ----

    # Clean: no fixable issues
    if ($fixableCount -eq 0) {
        Write-Host "`n  ** ALL CLEAR - No fixable issues remaining! **" -ForegroundColor Green
        Write-Log "Cycle ${cycle}: Clean - no issues at ${MinSeverityToFix}+ severity" "OK"
        break
    }

    # Review-only mode: just report
    if ($ReviewOnly) {
        Write-Log "Review-only mode - skipping fixes" "INFO"
        break
    }

    # Last cycle: don't fix, just report final state
    if ($cycle -eq $MaxCycles) {
        Write-Host "  Max cycles ($MaxCycles) reached. Remaining issues reported below." -ForegroundColor Yellow
        Write-Log "Max cycles reached with $fixableCount fixable issues remaining" "WARN"
        break
    }

    # Early-stop: if cycle 3+ and issues didn't drop by at least 10%, stop AFTER fixing
    # (cycle 2 always gets a chance to fix since model non-determinism causes oscillation)
    $earlyStop = $false
    if ($cycle -ge 3 -and $cycleHistory.Count -ge 2) {
        $prevIssues = $cycleHistory[-2].total_issues
        $currIssues = $allIssues.Count
        if ($prevIssues -gt 0) {
            $improvementPct = [math]::Round((($prevIssues - $currIssues) / $prevIssues) * 100, 1)
            Write-Host "  Convergence: $prevIssues -> $currIssues issues ($improvementPct% improvement)" -ForegroundColor $(if ($improvementPct -ge 10) { "Green" } else { "Yellow" })
            Write-Log "Convergence check: $prevIssues -> $currIssues ($improvementPct%)" "INFO"
            if ($improvementPct -lt 10) {
                Write-Host "  ** Will stop after applying fixes (diminishing returns). **" -ForegroundColor Yellow
                Write-Log "Will early-stop after fixes: only $improvementPct% improvement (threshold: 10%)" "WARN"
                $earlyStop = $true
            }
        }
    }

    # ---- FIX PHASE ----
    Write-Host "`n--- Fixing $fixableCount issue(s) with $FixModel ---" -ForegroundColor Magenta

    # Group fixable issues by file
    $fixableIssues = @($allIssues | Where-Object { $severityRank[$_.severity] -ge $minFixRank })
    $issuesByFile = @{}
    foreach ($issue in $fixableIssues) {
        $key = $issue.full_path
        if (-not $key) { $key = $issue.file }
        if (-not $issuesByFile.ContainsKey($key)) { $issuesByFile[$key] = @() }
        $issuesByFile[$key] += $issue
    }

    $fixedCount = 0
    $fixFailCount = 0
    foreach ($filePath in $issuesByFile.Keys) {
        $fileIssues = $issuesByFile[$filePath]
        $relPath = $fileIssues[0].file

        # Deduplicate issues (different models may flag same thing)
        $uniqueIssues = @()
        $seenIssueTexts = @{}
        foreach ($fi in $fileIssues) {
            $key = "$($fi.issue)::$($fi.suggestion)"
            if (-not $seenIssueTexts.ContainsKey($key)) {
                $seenIssueTexts[$key] = $true
                $uniqueIssues += $fi
            }
        }

        Write-Host "  Fixing $($uniqueIssues.Count) issue(s) in: $relPath" -ForegroundColor Magenta

        $fixed = Invoke-FixFile -FilePath $filePath -RelPath $relPath -Issues $uniqueIssues -Model $FixModel
        if ($fixed) {
            $fixedCount++
        } else {
            $fixFailCount++
        }
    }

    Write-Log "Cycle ${cycle} fix results: ${fixedCount} files fixed, ${fixFailCount} failed" $(if ($fixedCount -gt 0) { "FIX" } else { "WARN" })

    # Regenerate traceability matrix after fixes to keep evidence paths current
    if ($fixedCount -gt 0 -and (Get-Command Invoke-TraceabilityUpdate -ErrorAction SilentlyContinue)) {
        Write-Host "  Updating traceability matrix after fixes..." -ForegroundColor Cyan
        $traceResult = Invoke-TraceabilityUpdate -RepoRoot $RepoRoot -GsdDir $GsdDir
        if ($traceResult.Success) {
            Write-Log "Traceability updated: $($traceResult.Mapped) mapped, $($traceResult.Unmapped) unmapped" "OK"
            # Reload traceability for next review cycle
            $traceability = Get-Content (Join-Path $GsdDir "compliance/traceability-matrix.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $traceEntries = @()
            if ($traceability.entries) { $traceEntries = @($traceability.entries) }
            elseif ($traceability.requirements) { $traceEntries = @($traceability.requirements) }
            # Rebuild trace map
            $traceMap = @{}
            foreach ($entry in $traceEntries) {
                $reqId = $entry.requirement_id
                if (-not $reqId) { $reqId = $entry.req_id }
                if (-not $reqId) { $reqId = $entry.id }
                if (-not $reqId) { continue }
                $files = @()
                if ($entry.evidence_files) { $files += @($entry.evidence_files) }
                if ($entry.source_files) { $files += @($entry.source_files) }
                if ($entry.files) { $files += @($entry.files) }
                if ($entry.target_files) { $files += @($entry.target_files) }
                $traceMap[$reqId] = @($files | Select-Object -Unique)
            }
        }
    }

    if ($fixedCount -eq 0) {
        Write-Host "  No files were fixed - stopping to prevent infinite loop." -ForegroundColor Yellow
        Write-Log "No fixes applied in cycle $cycle - stopping" "WARN"
        break
    }

    # Early-stop after fixing: still applied the fixes, but don't re-review again
    if ($earlyStop) {
        Write-Host "  ** EARLY STOP after fixes applied — diminishing returns. **" -ForegroundColor Yellow
        Write-Log "Early stop after applying fixes in cycle $cycle" "WARN"
        break
    }

    Write-Host "  Proceeding to re-review..." -ForegroundColor Cyan
    Start-Sleep -Seconds 2  # Brief pause between cycles
}

# ============================================================
# BUILD FINAL REPORT
# ============================================================

Write-Host "`n--- Building Final Report ---" -ForegroundColor Yellow

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

$overallDuration = ((Get-Date) - $overallStartTime).TotalMinutes

$report = @{
    generated_at          = (Get-Date -Format "o")
    repo                  = $RepoRoot
    mode                  = if ($ReviewOnly) { "review_only" } else { "review_and_fix" }
    models_used           = $selectedModels
    fix_model             = if (-not $ReviewOnly) { $FixModel } else { "n/a" }
    cycles_completed      = $cycle
    max_cycles            = $MaxCycles
    duration_minutes      = [math]::Round($overallDuration, 1)
    requirements_reviewed = $reviewedCount
    requirements_skipped  = $skippedCount
    api_errors            = $script:totalErrors
    final_issues          = $allIssues.Count
    by_severity           = $bySeverity
    by_model              = $byModel
    by_category           = $byCategory
    cycle_history         = $cycleHistory
    issues                = $allIssues
}

# Write report files
$reviewDir = Join-Path $GsdDir "code-review"
if (-not (Test-Path $reviewDir)) { New-Item -ItemType Directory -Path $reviewDir -Force | Out-Null }

$reportPath = Join-Path $reviewDir "review-report.json"
$report | ConvertTo-Json -Depth 10 | Set-Content $reportPath -Encoding UTF8
Write-Log "Report saved: $reportPath" "OK"

# Markdown summary
$summaryPath = Join-Path $reviewDir "review-summary.md"
$summaryLines = @()
$summaryLines += "# Code Review Report"
$summaryLines += ""
$summaryLines += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$summaryLines += "Repo: ``$repoName``"
$summaryLines += "Mode: **$modeLabel**"
$summaryLines += "Review models: $($selectedModels -join ', ') | Fix model: $FixModel"
$summaryLines += ""
$summaryLines += "## Cycle History"
$summaryLines += ""
$summaryLines += "| Cycle | Total | Critical | High | Medium | Low | Fixable |"
$summaryLines += "|-------|-------|----------|------|--------|-----|---------|"
foreach ($ch in $cycleHistory) {
    $summaryLines += "| $($ch.cycle) | $($ch.total_issues) | $($ch.critical) | $($ch.high) | $($ch.medium) | $($ch.low) | $($ch.fixable) |"
}
$summaryLines += ""
$summaryLines += "**Duration**: $([math]::Round($overallDuration, 1)) minutes | **Cycles**: $cycle / $MaxCycles"
$summaryLines += ""
$summaryLines += "## Final Summary"
$summaryLines += ""
$summaryLines += "| Metric | Value |"
$summaryLines += "|--------|-------|"
$summaryLines += "| Requirements reviewed | $reviewedCount |"
$summaryLines += "| Requirements skipped | $skippedCount |"
$summaryLines += "| Final issues remaining | $($allIssues.Count) |"
$summaryLines += "| API errors | $($script:totalErrors) |"
$summaryLines += ""
$summaryLines += "## Final Issues by Severity"
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

# Critical and high issues detail
$criticalHigh = @($allIssues | Where-Object { $_.severity -in @("critical","high") })
if ($criticalHigh.Count -gt 0) {
    $summaryLines += ""
    $summaryLines += "## Remaining Critical & High Issues"
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

# Medium/low compact table
$mediumLow = @($allIssues | Where-Object { $_.severity -in @("medium","low") })
if ($mediumLow.Count -gt 0) {
    $summaryLines += ""
    $summaryLines += "## Remaining Medium & Low Issues"
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
# PRINT FINAL STATS
# ============================================================

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  CODE REVIEW COMPLETE" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Mode:     $modeLabel" -ForegroundColor White
Write-Host "  Cycles:   $cycle / $MaxCycles" -ForegroundColor White
Write-Host "  Duration: $([math]::Round($overallDuration, 1)) min" -ForegroundColor White
Write-Host "  Reviewed: $reviewedCount | Skipped: $skippedCount" -ForegroundColor White
Write-Host "" -NoNewline

$finalTotal = $allIssues.Count
Write-Host "  Final issues: $finalTotal" -ForegroundColor $(if ($finalTotal -eq 0) { "Green" } else { "Yellow" })

$critColor = if ($bySeverity.critical -gt 0) { "Red" } else { "Green" }
$highColor = if ($bySeverity.high -gt 0) { "Yellow" } else { "Green" }
Write-Host "    Critical: $($bySeverity.critical)" -ForegroundColor $critColor
Write-Host "    High:     $($bySeverity.high)" -ForegroundColor $highColor
Write-Host "    Medium:   $($bySeverity.medium)" -ForegroundColor White
Write-Host "    Low:      $($bySeverity.low)" -ForegroundColor DarkGray

if ($cycleHistory.Count -gt 1) {
    Write-Host "" -NoNewline
    Write-Host "  Cycle progression:" -ForegroundColor White
    foreach ($ch in $cycleHistory) {
        $arrow = if ($ch.cycle -eq 1) { "" } else { " <- " }
        Write-Host "    Cycle $($ch.cycle): $($ch.total_issues) issues (C:$($ch.critical) H:$($ch.high) M:$($ch.medium) L:$($ch.low))" -ForegroundColor DarkGray
    }
}

Write-Host "" -NoNewline
Write-Host "  API errors: $($script:totalErrors)" -ForegroundColor $(if ($script:totalErrors -gt 0) { "Yellow" } else { "DarkGray" })
Write-Host "  Report:  $reportPath" -ForegroundColor DarkGray
Write-Host "  Summary: $summaryPath" -ForegroundColor DarkGray

if (Get-Command Get-TotalCost -ErrorAction SilentlyContinue) {
    Write-Host "  Cost:    `$$(Get-TotalCost)" -ForegroundColor DarkGray
}

# Final traceability update if any fixes were applied across all cycles
$totalFixesAllCycles = ($cycleHistory | ForEach-Object { if ($_.fixable) { $_.fixable } else { 0 } } | Measure-Object -Sum).Sum
if ($totalFixesAllCycles -gt 0 -and (Get-Command Invoke-TraceabilityUpdate -ErrorAction SilentlyContinue)) {
    Write-Host "" -NoNewline
    Write-Host "  --- Final Traceability Update ---" -ForegroundColor Cyan
    $finalTrace = Invoke-TraceabilityUpdate -RepoRoot $RepoRoot -GsdDir $GsdDir
    if ($finalTrace.Success) {
        Write-Host "  Traceability: $($finalTrace.Mapped)/$($finalTrace.Total) reqs mapped to files ($($finalTrace.ElapsedSec)s)" -ForegroundColor Green
    }
}

Write-Host "============================================`n" -ForegroundColor Cyan

# ============================================================
# OPTIONAL: Run Smoke Test after Code Review
# ============================================================

if ($RunSmokeTest) {
    Write-Host "`n============================================" -ForegroundColor Cyan
    Write-Host "  LAUNCHING SMOKE TEST (post-code-review)" -ForegroundColor Cyan
    Write-Host "============================================`n" -ForegroundColor Cyan

    $smokeScript = Join-Path $PSScriptRoot "gsd-smoketest.ps1"
    if (-not (Test-Path $smokeScript)) {
        Write-Host "  [ERROR] gsd-smoketest.ps1 not found at $smokeScript" -ForegroundColor Red
        Write-Log "Smoke test script not found: $smokeScript" "ERROR"
    }
    else {
        $smokeArgs = @{
            RepoRoot = $RepoRoot
            FixModel = $FixModel
        }
        if ($ConnectionString) { $smokeArgs.ConnectionString = $ConnectionString }
        if ($TestUsers) { $smokeArgs.TestUsers = $TestUsers }
        if ($AzureAdConfig) { $smokeArgs.AzureAdConfig = $AzureAdConfig }

        Write-Log "Invoking smoke test: $smokeScript" "INFO"
        & $smokeScript @smokeArgs
        $smokeExitCode = $LASTEXITCODE
        Write-Log "Smoke test completed with exit code: $smokeExitCode" $(if ($smokeExitCode -eq 0) { "OK" } else { "WARN" })
    }
}

# Return exit code: 0 if no critical/high issues remain, 1 otherwise
exit $(if (($bySeverity.critical + $bySeverity.high) -gt 0) { 1 } else { 0 })
