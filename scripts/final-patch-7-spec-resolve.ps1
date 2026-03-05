<#
.SYNOPSIS
    Final Integration Sub-Patch 7: Spec Conflict Auto-Resolution
    Adds Gemini-powered auto-resolution of spec contradictions detected by the spec auditor.
    Uses Gemini (--yolo) to save Claude/Codex quota for code generation.
    New flag: -AutoResolve on gsd-blueprint and gsd-converge
#>
param([string]$UserHome = $env:USERPROFILE)
$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$GlobalDir = Join-Path $UserHome ".gsd-global"
$LibFile = Join-Path $GlobalDir "lib\modules\resilience.ps1"
$PromptDir = Join-Path $GlobalDir "prompts\gemini"

if (-not (Test-Path $LibFile)) {
    Write-Host "Run prior patches first." -ForegroundColor Red; exit 1
}

Write-Host "[WRENCH] Sub-patch 7: Spec conflict auto-resolution..." -ForegroundColor Yellow

# ========================================
# 1. Create Codex prompt template
# ========================================

$promptContent = @'
# GSD Spec Conflict Resolution - Gemini Phase

You are a SPEC RESOLVER. Fix contradictions found in specification documents
so the autonomous pipeline can proceed without blocking.

## Context
- Project .gsd dir: {{GSD_DIR}}
- Repo root: {{REPO_ROOT}}
- Resolution attempt: {{ATTEMPT}} of {{MAX_ATTEMPTS}}

## Read FIRST
1. {{GSD_DIR}}\spec-conflicts\conflicts-to-resolve.json - THE CONFLICTS TO FIX
2. {{GSD_DIR}}\spec-consistency-report.json - full audit report for context
3. {{GSD_DIR}}\spec-consistency-report.md - human-readable audit
4. docs\ - SDLC specification documents (you may edit these)
{{INTERFACE_SOURCES}}

## Conflict Resolution Rules

For each conflict, read the `recommendation` field and follow it. If the recommendation
is unclear, apply these priority rules:

| Conflict Type | Authoritative Source | Action |
|--------------|---------------------|--------|
| data_type | Database schema / data model spec | Align other docs to match DB definition |
| api_contract | OpenAPI spec (Phase E 02_openapi_final.yaml) | Align other docs to match API contract |
| navigation | Latest Figma analysis (_analysis/ deliverables) | Align docs to match design |
| business_rule | SDLC Phase B requirements | Pick the more restrictive/secure interpretation |
| design_system | Figma design tokens (_analysis/ deliverables) | Align docs to match design tokens |
| database | SDLC Phase D data model spec | Align other docs to match DB spec |
| missing_ref | Add the missing reference | Create the cross-reference in the appropriate file |

## Execution Steps

For EACH conflict in conflicts-to-resolve.json:
1. Read both source_a and source_b files completely
2. Determine which source is authoritative (see table above)
3. Edit the NON-authoritative source to align with the authoritative one
4. If adding a missing reference, add it to the most appropriate existing file
5. Make MINIMAL changes - only fix the specific contradiction, do NOT rewrite entire sections
6. Preserve all document formatting, structure, and surrounding content

## After Resolving ALL Conflicts

Write a resolution summary to: {{GSD_DIR}}\spec-conflicts\resolution-summary.md

Format:
```markdown
# Spec Conflict Resolution Summary
Attempt: {{ATTEMPT}} | Date: (current date)

## Resolved
| # | Type | Description | File Changed | What Changed |
|---|------|-------------|--------------|--------------|
| 1 | data_type | ... | docs/... | Aligned enum to match DB |

## Could Not Auto-Resolve (requires human)
| # | Type | Description | Reason |
|---|------|-------------|--------|
```

Append a single line to: {{GSD_DIR}}\spec-conflicts\resolution-log.jsonl
{"agent":"gemini","action":"resolve-conflicts","attempt":{{ATTEMPT}},"conflicts_resolved":N,"conflicts_skipped":N,"files_modified":["file1","file2"],"timestamp":"(ISO 8601)"}

## Boundaries - STRICTLY ENFORCED
- ONLY modify files in: docs\, and interface _analysis\ directories
- ONLY write to: {{GSD_DIR}}\spec-conflicts\
- DO NOT modify source code files (.cs, .tsx, .sql, .js, .ts, .css, .html, etc.)
- DO NOT modify: {{GSD_DIR}}\health\, {{GSD_DIR}}\code-review\, {{GSD_DIR}}\generation-queue\
- DO NOT modify: {{GSD_DIR}}\spec-consistency-report.json (the auditor's output)
- DO NOT modify: {{GSD_DIR}}\blueprint\ (pipeline state)

Be thorough but fast. Fix every conflict you can. Under 3000 tokens output.
'@

if (-not (Test-Path $PromptDir)) { New-Item -ItemType Directory -Path $PromptDir -Force | Out-Null }
Set-Content -Path (Join-Path $PromptDir "resolve-spec-conflicts.md") -Value $promptContent -Encoding UTF8
Write-Host "   [OK] prompts\gemini\resolve-spec-conflicts.md" -ForegroundColor DarkGreen

# ========================================
# 2. Add Invoke-SpecConflictResolution to resilience.ps1
# ========================================

$code = @'

# ===============================================================
# SPEC CONFLICT AUTO-RESOLUTION - Gemini resolves contradictions
# (saves Claude/Codex quota for code generation)
# ===============================================================

function Invoke-SpecConflictResolution {
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [array]$Interfaces,
        [array]$Conflicts,
        [array]$Warnings,
        [int]$MaxResolveAttempts = 2,
        [switch]$DryRun
    )

    $totalConflicts = $Conflicts.Count
    Write-Host "  [WRENCH] Auto-resolving $totalConflicts spec conflict(s) via Gemini..." -ForegroundColor Cyan

    # Create spec-conflicts directory
    $conflictsDir = Join-Path $GsdDir "spec-conflicts"
    if (-not (Test-Path $conflictsDir)) {
        New-Item -ItemType Directory -Path $conflictsDir -Force | Out-Null
    }

    # Build interface source paths for prompt
    $ifaceSources = ""
    foreach ($iface in $Interfaces) {
        if ($iface.HasAnalysis) {
            $ifaceSources += "5. $($iface.VersionPath)\_analysis\ - $($iface.Label) deliverables`n"
        }
    }

    # Load prompt template
    $promptTemplatePath = Join-Path $env:USERPROFILE ".gsd-global\prompts\gemini\resolve-spec-conflicts.md"
    if (-not (Test-Path $promptTemplatePath)) {
        Write-Host "    [XX] Prompt template not found: $promptTemplatePath" -ForegroundColor Red
        return @{ Resolved = $false; Attempts = 0 }
    }
    $promptTemplate = Get-Content $promptTemplatePath -Raw

    # Resolution loop
    for ($attempt = 1; $attempt -le $MaxResolveAttempts; $attempt++) {
        Write-Host "    Attempt $attempt/$MaxResolveAttempts (batch: $($Conflicts.Count))..." -ForegroundColor DarkCyan

        # Write conflicts-to-resolve.json for this attempt
        $conflictsFile = Join-Path $conflictsDir "conflicts-to-resolve.json"
        $resolvePayload = @{
            generated_at = (Get-Date -Format "o")
            resolve_attempt = $attempt
            total_critical = $Conflicts.Count
            total_warnings = if ($Warnings) { $Warnings.Count } else { 0 }
            conflicts = @($Conflicts) + @($Warnings | Where-Object { $_ })
        } | ConvertTo-Json -Depth 5
        Set-Content -Path $conflictsFile -Value $resolvePayload -Encoding UTF8

        # Resolve prompt template variables
        $prompt = $promptTemplate.Replace("{{GSD_DIR}}", $GsdDir).Replace("{{REPO_ROOT}}", $RepoRoot).Replace("{{ATTEMPT}}", "$attempt").Replace("{{MAX_ATTEMPTS}}", "$MaxResolveAttempts").Replace("{{INTERFACE_SOURCES}}", $ifaceSources)

        if ($DryRun) {
            Write-Host "    [DRY RUN] codex -> resolve-spec-conflicts" -ForegroundColor DarkYellow
            return @{ Resolved = $false; Attempts = $attempt }
        }

        # Spawn Gemini agent via Invoke-WithRetry (saves Claude/Codex quota)
        $result = Invoke-WithRetry -Agent "gemini" -Prompt $prompt -Phase "spec-conflict-resolution" `
            -LogFile "$GsdDir\logs\spec-conflict-resolution.log" `
            -CurrentBatchSize 1 -GsdDir $GsdDir -MaxAttempts 2 `
            -GeminiMode "--yolo"

        if (-not $result.Success) {
            Write-Host "    [!!]  Resolution agent failed" -ForegroundColor DarkYellow
            if (Get-Command Write-GsdError -ErrorAction SilentlyContinue) {
                Write-GsdError -GsdDir $GsdDir -Category "agent_crash" -Phase "spec-conflict-resolution" `
                    -Iteration $attempt -Message "Gemini spec resolution failed" -Resolution "Manual fix required"
            }
            return @{ Resolved = $false; Attempts = $attempt }
        }

        # Re-run spec consistency check to verify resolution
        Write-Host "    Re-checking spec consistency..." -ForegroundColor Cyan
        $recheck = Invoke-SpecConsistencyCheck -RepoRoot $RepoRoot -GsdDir $GsdDir `
            -Interfaces $Interfaces

        if ($recheck.Passed) {
            Write-Host "    [OK] All conflicts resolved after $attempt attempt(s)!" -ForegroundColor Green

            # ── POST-SPEC-FIX COUNCIL ──
            # Validate Gemini's spec resolution via multi-agent review before declaring success
            if (Get-Command Invoke-LlmCouncil -ErrorAction SilentlyContinue) {
                Write-Host "    [SCALES] Post-spec-fix council review..." -ForegroundColor DarkCyan
                $councilResult = Invoke-LlmCouncil -RepoRoot $RepoRoot -GsdDir $GsdDir `
                    -Iteration $attempt -Health 0 -Pipeline "spec-fix" -CouncilType "post-spec-fix"
                if (-not $councilResult.Approved) {
                    $concernCount = if ($councilResult.Findings.concerns) { $councilResult.Findings.concerns.Count } else { 0 }
                    Write-Host "    [SCALES] Council found $concernCount concern(s) in spec resolution" -ForegroundColor Yellow
                    # If council blocks, treat as unresolved so next attempt picks up feedback
                    if ($attempt -lt $MaxResolveAttempts) {
                        Write-Host "    Retrying with council feedback..." -ForegroundColor DarkYellow
                        $Conflicts = @()  # Re-check will find any remaining issues
                        continue
                    }
                } else {
                    Write-Host "    [SCALES] Council approved spec resolution" -ForegroundColor Green
                }
            }

            return @{ Resolved = $true; Attempts = $attempt }
        }

        # Still have criticals - update for next attempt
        if ($attempt -lt $MaxResolveAttempts) {
            $remaining = $recheck.Conflicts.Count
            Write-Host "    [!!]  $remaining conflict(s) remain. Retrying..." -ForegroundColor DarkYellow
            $Conflicts = $recheck.Conflicts
            $Warnings = $recheck.Warnings
        }
    }

    # Exhausted all attempts
    Write-Host "    [XX] Could not auto-resolve all conflicts after $MaxResolveAttempts attempt(s)" -ForegroundColor Red
    Write-Host "    See: $conflictsDir\resolution-summary.md" -ForegroundColor Yellow
    Write-Host "    See: $conflictsDir\conflicts-to-resolve.json" -ForegroundColor Yellow
    return @{ Resolved = $false; Attempts = $MaxResolveAttempts }
}
'@

$existing = Get-Content $LibFile -Raw
if ($existing -match "SPEC CONFLICT AUTO-RESOLUTION") {
    $idx = $existing.IndexOf("`n# SPEC CONFLICT AUTO-RESOLUTION")
    if ($idx -gt 0) {
        $existing = $existing.Substring(0, $idx)
        Set-Content -Path $LibFile -Value $existing -Encoding UTF8
    }
    Add-Content -Path $LibFile -Value "`n$code" -Encoding UTF8
    Write-Host "   [OK] Invoke-SpecConflictResolution updated" -ForegroundColor DarkGreen
} else {
    Add-Content -Path $LibFile -Value "`n$code" -Encoding UTF8
    Write-Host "   [OK] Invoke-SpecConflictResolution added" -ForegroundColor DarkGreen
}

Write-Host "  [7/7] Complete" -ForegroundColor DarkGreen
