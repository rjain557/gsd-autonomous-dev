#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Write a lesson, mistake, or solution discovered mid-pipeline to the Obsidian vault.

.DESCRIPTION
    Called from phase-orchestrator whenever the pipeline:
    - Discovers a new disease/pattern
    - Finds a solution that works
    - Makes a mistake (wrong SP name, wrong table type, etc.)
    - Hits a schema surprise

    Writes to:
    - 07-Feedback/  for rules/corrections
    - 03-Patterns/diseases/  for new disease patterns
    - 03-Patterns/solutions/ for validated solutions
    - 02-Projects/{project}/index.md for schema surprises

.PARAMETER Type
    lesson | disease | solution | schema | feedback

.PARAMETER Project
    Project slug (e.g. "chatai-v8")

.PARAMETER Phase
    Phase where this was discovered.

.PARAMETER Title
    Short title for the lesson.

.PARAMETER Body
    Full markdown body of the lesson.

.PARAMETER Severity
    high | medium | low (for diseases)

.EXAMPLE
    & pwsh -File scripts/write-vault-lesson.ps1 `
        -Type "schema" `
        -Project "chatai-v8" `
        -Phase "execute" `
        -Title "ProjectShares.TenantId is uniqueidentifier not nvarchar" `
        -Body "Always check INFORMATION_SCHEMA.COLUMNS before writing SPs that join on TenantId."
#>
param(
    [string]$VaultRoot = "D:\obsidian\gsd-autonomous-dev\gsd-autonomous-dev",
    [ValidateSet("lesson","disease","solution","schema","feedback","mistake")]
    [string]$Type      = "lesson",
    [string]$Project   = "",
    [string]$Phase     = "",
    [string]$Title     = "",
    [string]$Body      = "",
    [string]$Severity  = "medium"
)

if (-not $Title) { Write-Warning "write-vault-lesson: -Title required"; exit 1 }
if (-not (Test-Path $VaultRoot)) { Write-Warning "write-vault-lesson: vault not found: $VaultRoot"; exit 1 }

$date = Get-Date -Format "yyyy-MM-dd"
$time = Get-Date -Format "HH:mm"
$slug = ($Title -replace '[^a-zA-Z0-9\s]','' -replace '\s+','-').ToLower().Substring(0,[Math]::Min(50,$Title.Length))

switch ($Type) {

    # ── Feedback rule (how to approach work differently) ──────────────────
    { $_ -in "lesson","feedback","mistake" } {
        $dir  = Join-Path $VaultRoot "07-Feedback"
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir | Out-Null }
        $file = Join-Path $dir "$date-$slug.md"
        $content = @"
---
type: feedback
date: $date
phase: $Phase
project: $Project
severity: $Severity
tags: [feedback, $Phase, $Project]
---

# $Title

$Body

**Discovered**: $date $time during `$Phase` phase on `$Project`
"@
        Set-Content $file $content -Encoding UTF8
        Write-Host "[Vault] Feedback written: $file"

        # Append to feedback index
        $idx = Join-Path $VaultRoot "07-Feedback\index.md"
        if (-not (Test-Path $idx)) {
            Set-Content $idx "# Feedback Index`n`n| Date | Title | Phase | Severity |`n|------|-------|-------|----------|`n" -Encoding UTF8
        }
        Add-Content $idx "| $date | [[$date-$slug\|$Title]] | $Phase | $Severity |" -Encoding UTF8
    }

    # ── New disease pattern ───────────────────────────────────────────────
    "disease" {
        $dir  = Join-Path $VaultRoot "03-Patterns\diseases"
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir | Out-Null }
        $existing = Get-ChildItem $dir -Filter "*.md" | Where-Object { $_.Name -ne "index.md" } | Measure-Object
        $num  = ($existing.Count + 1).ToString("00")
        $file = Join-Path $dir "$num-$slug.md"
        $content = @"
---
type: disease
name: $Title
severity: $Severity
status: open
first_seen: $date
phase: $Phase
project: $Project
tags: [disease, $Phase]
---

# $Title

$Body

**First seen**: $date during `$Phase` phase on `$Project`

## How to detect

(add detection criteria here)

## Mitigation

(add mitigation steps here)
"@
        Set-Content $file $content -Encoding UTF8
        Write-Host "[Vault] Disease written: $file"

        # Update diseases index
        $idx = Join-Path $VaultRoot "03-Patterns\diseases\index.md"
        if (Test-Path $idx) {
            Add-Content $idx "`n- [[$num-$slug|$Title]] — first seen $date on $Project ($Severity)" -Encoding UTF8
        }
    }

    # ── Validated solution ────────────────────────────────────────────────
    "solution" {
        $dir  = Join-Path $VaultRoot "03-Patterns\solutions"
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir | Out-Null }
        $file = Join-Path $dir "$slug.md"
        $content = @"
---
type: solution
name: $Title
date: $date
phase: $Phase
project: $Project
tags: [solution, $Phase]
---

# $Title

$Body

**Validated**: $date on `$Project` during `$Phase` phase
"@
        Set-Content $file $content -Encoding UTF8
        Write-Host "[Vault] Solution written: $file"

        # Update solutions index
        $patternsIdx = Join-Path $VaultRoot "03-Patterns\index.md"
        if (Test-Path $patternsIdx) {
            $existing = Get-Content $patternsIdx -Raw
            if ($existing -notmatch $slug) {
                $newLine = "- [[$slug|$Title]] — validated $date on $Project"
                $updated = $existing -replace "(## Validated Solutions.*?)(`n`n)", "`$1`n$newLine`$2"
                Set-Content $patternsIdx $updated -Encoding UTF8
            }
        }
    }

    # ── Schema surprise (append to project index) ─────────────────────────
    "schema" {
        if (-not $Project) { Write-Warning "schema lesson requires -Project"; exit 1 }
        $projectIndex = Join-Path $VaultRoot "02-Projects\$Project\index.md"
        if (Test-Path $projectIndex) {
            $note = "`n### Schema Note ($date): $Title`n`n$Body`n"
            Add-Content $projectIndex $note -Encoding UTF8
            Write-Host "[Vault] Schema note appended to: $projectIndex"
        } else {
            Write-Warning "write-vault-lesson: project index not found: $projectIndex"
        }
    }
}

Write-Host "[Vault] Done. Type=$Type Title='$Title'"
