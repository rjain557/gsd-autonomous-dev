#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Read relevant Obsidian vault knowledge for injection into pipeline prompts.

.DESCRIPTION
    Called at the START of each phase to surface accumulated patterns, diseases,
    solutions, and project-specific schema notes so every LLM call benefits
    from lessons already learned.

    Output is Markdown text suitable for insertion into {{VAULT_KNOWLEDGE}}
    prompt placeholder.

.PARAMETER VaultRoot
    Root of the Obsidian vault.

.PARAMETER Project
    Project slug (e.g. "chatai-v8").

.PARAMETER Phase
    Current pipeline phase: plan | review | verify | execute | spec-gate | research

.PARAMETER MaxTokens
    Approximate character budget for output (default 2000 — ~500 tokens).

.EXAMPLE
    $ctx = & pwsh -File scripts/read-vault-context.ps1 -Project "chatai-v8" -Phase "review"
#>
param(
    [string]$VaultRoot  = "D:\obsidian\gsd-autonomous-dev\gsd-autonomous-dev",
    [string]$Project    = "",
    [string]$Phase      = "plan",
    [int]   $MaxTokens  = 2000
)

if (-not (Test-Path $VaultRoot)) {
    Write-Output "<!-- vault not found -->"
    exit 0
}

$sb = [System.Text.StringBuilder]::new()

# ── Helper ─────────────────────────────────────────────────────────────────
function Append([string]$text) { [void]$sb.AppendLine($text) }
function AppendFile([string]$path, [int]$maxLines = 40) {
    if (Test-Path $path) {
        $lines = Get-Content $path | Select-Object -First $maxLines
        foreach ($line in $lines) { Append $line }
    }
}
function Under([int]$budget) { $sb.Length -lt $budget }

# ── 1. Active diseases (always inject — every phase needs to know what to watch for) ──
Append "## Known Pipeline Diseases (watch for these)"
$diseaseDir = Join-Path $VaultRoot "03-Patterns\diseases"
if (Test-Path $diseaseDir) {
    $diseases = Get-ChildItem $diseaseDir -Filter "*.md" | Where-Object { $_.Name -ne "index.md" } | Sort-Object Name
    foreach ($d in $diseases) {
        if (-not (Under $MaxTokens)) { break }
        $content = Get-Content $d.FullName -Raw
        # Extract name and first non-frontmatter line
        $title = $d.BaseName -replace "^\d+-",""
        $firstLine = ($content -split "`n" | Where-Object { $_ -notmatch "^---" -and $_.Trim() -ne "" } | Select-Object -First 3) -join " "
        Append "- **$title**: $($firstLine.Substring(0, [Math]::Min(120, $firstLine.Length)))"
    }
}
Append ""

# ── 2. Phase-relevant solutions ────────────────────────────────────────────
$solutionDir = Join-Path $VaultRoot "03-Patterns\solutions"
if ((Test-Path $solutionDir) -and (Under $MaxTokens)) {

    $phaseRelevantSolutions = @{
        "plan"      = @("direct-fix-pattern", "mock-to-db-pipeline", "figma-design-restoration")
        "review"    = @("direct-fix-pattern", "auto-promote-pattern")
        "verify"    = @("auto-promote-pattern", "direct-fix-pattern")
        "execute"   = @("mock-to-db-pipeline", "figma-design-restoration")
        "spec-gate" = @("spec-alignment-guard")
        "research"  = @("mock-to-db-pipeline")
    }

    $relevant = $phaseRelevantSolutions[$Phase.ToLower()] ?? @()
    if ($relevant.Count -gt 0) {
        Append "## Validated Solutions (use these approaches)"
        foreach ($sol in $relevant) {
            $solPath = Join-Path $solutionDir "$sol.md"
            if ((Test-Path $solPath) -and (Under $MaxTokens)) {
                $content = Get-Content $solPath -Raw
                # Strip frontmatter, take first 600 chars
                $stripped = ($content -replace "(?s)^---.*?---\s*", "").Trim()
                $excerpt  = $stripped.Substring(0, [Math]::Min(600, $stripped.Length))
                Append "### $sol"
                Append $excerpt
                Append ""
            }
        }
    }
}

# ── 3. Project-specific schema notes (review + execute phases) ─────────────
if ($Project -and ($Phase -in @("review","execute","plan")) -and (Under $MaxTokens)) {
    $projectIndex = Join-Path $VaultRoot "02-Projects\$Project\index.md"
    if (Test-Path $projectIndex) {
        $content = Get-Content $projectIndex -Raw
        # Extract just the Schema Notes or Key Findings sections
        if ($content -match "(?s)(#+\s*(Schema|Critical|Key Fix|Architecture).*?)(#+\s)") {
            $section = $Matches[1]
            $excerpt = $section.Substring(0, [Math]::Min(800, $section.Length))
            Append "## Project-Specific Notes ($Project)"
            Append $excerpt
            Append ""
        }
    }
}

# ── 4. Feedback rules (always inject) ─────────────────────────────────────
$feedbackDir = Join-Path $VaultRoot "07-Feedback"
if ((Test-Path $feedbackDir) -and (Under $MaxTokens)) {
    $feedbacks = Get-ChildItem $feedbackDir -Filter "*.md" | Where-Object { $_.Name -ne "index.md" } | Sort-Object LastWriteTime -Descending | Select-Object -First 5
    if ($feedbacks.Count -gt 0) {
        Append "## Standing Rules (feedback from past runs)"
        foreach ($f in $feedbacks) {
            if (-not (Under $MaxTokens)) { break }
            $lines = Get-Content $f.FullName | Where-Object { $_ -notmatch "^---" -and $_.Trim() -ne "" } | Select-Object -First 3
            $rule = $lines -join " "
            Append "- $($rule.Substring(0, [Math]::Min(150, $rule.Length)))"
        }
        Append ""
    }
}

# ── Output ─────────────────────────────────────────────────────────────────
$result = $sb.ToString().Trim()
if ($result.Length -lt 10) {
    Write-Output "<!-- no vault context available -->"
} else {
    Write-Output $result
}
