<#
.SYNOPSIS
    Differential Code Review - Only review changed files, cache reviewed state.
    Run AFTER patch-gsd-multi-model.ps1.

.DESCRIPTION
    Dramatically speeds up the code-review phase by reviewing only files that
    changed since the last successful review, instead of re-reviewing the entire
    codebase every iteration.

    Adds:
    1. Get-DifferentialContext function to resilience.ps1
       - Computes git diff since last reviewed commit
       - Builds a focused review payload (changed files + hunks only)
       - Maintains reviewed-files.json cache (.gsd/cache/reviewed-files.json)
       - Falls back to full review if cache is empty or >50% files changed

    2. code-review-differential.md prompt template for Claude
       - Optimized for diff-based review (smaller context, faster response)
       - Still outputs same health/matrix/drift-report format

    3. Config: differential_review block in global-config.json
       - enabled (default true)
       - max_diff_pct (50 -- above this, fall back to full review)
       - cache_ttl_iterations (10 -- rebuild cache every 10 iterations)

    4. Pipeline integration in convergence-loop.ps1
       - Before code-review phase, calls Get-DifferentialContext
       - If differential mode applies, uses code-review-differential.md
       - Otherwise falls through to full review

.INSTALL_ORDER
    1-21. (existing scripts)
    22. patch-gsd-differential-review.ps1  <- this file
#>

param([string]$UserHome = $env:USERPROFILE)
$ErrorActionPreference = "Stop"

$GsdGlobalDir = Join-Path $UserHome ".gsd-global"

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  GSD Differential Code Review" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

# ── 1. Add differential_review config to global-config.json ──

$configPath = Join-Path $GsdGlobalDir "config\global-config.json"
if (Test-Path $configPath) {
    $config = Get-Content $configPath -Raw | ConvertFrom-Json

    if (-not $config.differential_review) {
        $config | Add-Member -NotePropertyName "differential_review" -NotePropertyValue ([PSCustomObject]@{
            enabled              = $true
            max_diff_pct         = 50
            cache_ttl_iterations = 10
        })
        $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath -Encoding UTF8
        Write-Host "  [OK] Added differential_review config to global-config.json" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] differential_review already exists in global-config.json" -ForegroundColor DarkGray
    }
} else {
    Write-Host "  [WARN] global-config.json not found at $configPath" -ForegroundColor Yellow
}

# ── 2. Create code-review-differential.md prompt template ──

$promptDir = Join-Path $GsdGlobalDir "prompts\claude"
$promptPath = Join-Path $promptDir "code-review-differential.md"

if (-not (Test-Path $promptDir)) {
    New-Item -Path $promptDir -ItemType Directory -Force | Out-Null
}

$diffReviewPrompt = @'
# GSD Differential Code Review - Iteration {{ITERATION}}

## Output Constraints
- Maximum output: 3000 tokens
- Format: JSON health update + markdown drift report (no prose paragraphs)
- Truncate least-critical findings if approaching limit

## Input Context
You will receive: requirements-matrix.json, the git diff of changed files since last review, and the current health score.
Previous phase output: drift-report.md (max 50 lines from last iteration)

You are the CODE REVIEWER. Review ONLY the changed files shown below and update requirement statuses.

## Context
- Iteration: {{ITERATION}}
- Current Health: {{HEALTH}}%
- Project .gsd dir: {{GSD_DIR}}
- This is a DIFFERENTIAL review -- only changed files are shown below.

## Changed Files (git diff)
{{DIFF_CONTENT}}

## Changed File List
{{CHANGED_FILES}}

## Instructions

1. Read {{GSD_DIR}}\health\requirements-matrix.json
2. For EACH requirement in the matrix:
   - If the requirement's target files are in the changed file list: re-evaluate status
   - If the requirement's target files are NOT in the changed file list: KEEP existing status unchanged
   - Status values: "satisfied" | "partial" | "not_started"
3. Calculate health_score = (satisfied_count / total_count) * 100
4. Write updated requirements-matrix.json to {{GSD_DIR}}\health\requirements-matrix.json
5. Write health-current.json to {{GSD_DIR}}\health\health-current.json:
   {"health_score": N, "satisfied": N, "partial": N, "not_started": N, "total": N, "iteration": {{ITERATION}}, "timestamp": "..."}
6. Append to {{GSD_DIR}}\health\health-history.jsonl (one JSON line)
7. Write drift-report.md (max 50 lines) to {{GSD_DIR}}\code-review\drift-report.md
8. Write review-current.md (max 100 lines) to {{GSD_DIR}}\code-review\review-current.md
   - Focus ONLY on issues in changed files
   - Reference unchanged requirements as "stable (no changes)"

## Project Standards Reference
- Backend: .NET 8, Dapper, SQL Server stored procedures ONLY
- Frontend: React 18, functional components, hooks
- Compliance: HIPAA, SOC 2, PCI, GDPR
- See coding-conventions.md and security-standards.md for full rules

{{INTERFACE_CONTEXT}}

## Boundaries
- DO NOT modify source code files
- WRITE to: {{GSD_DIR}}\health\, {{GSD_DIR}}\code-review\ ONLY
'@

Set-Content -Path $promptPath -Value $diffReviewPrompt -Encoding UTF8
Write-Host "  [OK] Created code-review-differential.md prompt template" -ForegroundColor Green

# ── 3. Add Get-DifferentialContext function to resilience.ps1 ──

$resilienceFile = Join-Path $GsdGlobalDir "lib\modules\resilience.ps1"
if (Test-Path $resilienceFile) {
    $existing = Get-Content $resilienceFile -Raw

    if ($existing -notlike "*function Get-DifferentialContext*") {

        $diffFunction = @'

# ===========================================
# DIFFERENTIAL CODE REVIEW
# ===========================================

function Get-DifferentialContext {
    param(
        [string]$GsdDir,
        [string]$GlobalDir,
        [int]$Iteration,
        [string]$RepoRoot
    )

    $result = @{
        UseDifferential = $false
        DiffContent     = ""
        ChangedFiles    = @()
        Reason          = ""
    }

    # Check config
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (-not (Test-Path $configPath)) {
        $result.Reason = "No global-config.json"
        return $result
    }

    try {
        $config = Get-Content $configPath -Raw | ConvertFrom-Json
    } catch {
        $result.Reason = "Failed to parse global-config.json"
        return $result
    }

    $diffCfg = $config.differential_review
    if (-not $diffCfg -or -not $diffCfg.enabled) {
        $result.Reason = "Differential review disabled in config"
        return $result
    }

    # Check cache
    $cacheDir = Join-Path $GsdDir "cache"
    if (-not (Test-Path $cacheDir)) {
        New-Item -Path $cacheDir -ItemType Directory -Force | Out-Null
    }
    $cachePath = Join-Path $cacheDir "reviewed-files.json"

    # Get last reviewed commit
    $lastCommit = $null
    if (Test-Path $cachePath) {
        try {
            $cache = Get-Content $cachePath -Raw | ConvertFrom-Json
            $lastCommit = $cache.last_reviewed_commit
            $lastIteration = [int]$cache.last_iteration

            # Check cache TTL
            $ttl = [int]$diffCfg.cache_ttl_iterations
            if ($ttl -gt 0 -and ($Iteration - $lastIteration) -ge $ttl) {
                $result.Reason = "Cache TTL expired (last: iter $lastIteration, current: iter $Iteration, TTL: $ttl)"
                return $result
            }
        } catch {
            $result.Reason = "Failed to parse reviewed-files cache"
            return $result
        }
    } else {
        $result.Reason = "No reviewed-files cache (first run)"
        return $result
    }

    if (-not $lastCommit) {
        $result.Reason = "No last_reviewed_commit in cache"
        return $result
    }

    # Verify commit still exists
    $commitExists = git rev-parse --verify "$lastCommit^{commit}" 2>$null
    if (-not $commitExists) {
        $result.Reason = "Last reviewed commit $lastCommit no longer exists"
        return $result
    }

    # Get changed files
    $changedFiles = @(git diff --name-only $lastCommit HEAD 2>$null)

    if ($changedFiles.Count -eq 0) {
        $result.Reason = "No files changed since last review"
        $result.UseDifferential = $true
        $result.ChangedFiles = @()
        return $result
    }

    # Filter out .gsd/ and non-source files
    $sourceFiles = $changedFiles | Where-Object {
        $_ -notlike ".gsd/*" -and
        $_ -notlike "node_modules/*" -and
        $_ -notlike "bin/*" -and
        $_ -notlike "obj/*" -and
        $_ -notlike ".git/*" -and
        $_ -notlike "dist/*" -and
        $_ -notlike "build/*"
    }

    # Check diff percentage
    $totalFiles = @(git ls-files 2>$null | Where-Object {
        $_ -notlike "node_modules/*" -and $_ -notlike "bin/*" -and
        $_ -notlike "obj/*" -and $_ -notlike ".git/*"
    })

    if ($totalFiles.Count -gt 0) {
        $diffPct = [math]::Round(($sourceFiles.Count / $totalFiles.Count) * 100, 1)
        $maxPct = [int]$diffCfg.max_diff_pct

        if ($diffPct -gt $maxPct) {
            $result.Reason = "Diff too large: $diffPct% > max $maxPct% ($($sourceFiles.Count)/$($totalFiles.Count) files)"
            return $result
        }
    }

    # Get actual diff content (truncated to 50KB to avoid token overflow)
    $diffOutput = git diff $lastCommit HEAD -- $sourceFiles 2>$null
    if ($diffOutput.Length -gt 51200) {
        $diffOutput = $diffOutput.Substring(0, 51200) + "`n... (diff truncated at 50KB)"
    }

    $result.UseDifferential = $true
    $result.DiffContent = $diffOutput
    $result.ChangedFiles = $sourceFiles
    $result.Reason = "Differential: $($sourceFiles.Count) files changed ($diffPct%)"

    return $result
}

function Save-ReviewedCommit {
    param(
        [string]$GsdDir,
        [int]$Iteration
    )

    $cacheDir = Join-Path $GsdDir "cache"
    if (-not (Test-Path $cacheDir)) {
        New-Item -Path $cacheDir -ItemType Directory -Force | Out-Null
    }

    $currentCommit = git rev-parse HEAD 2>$null
    if ($currentCommit) {
        $cache = @{
            last_reviewed_commit = $currentCommit
            last_iteration       = $Iteration
            timestamp            = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        }
        $cachePath = Join-Path $cacheDir "reviewed-files.json"
        $cache | ConvertTo-Json -Depth 5 | Set-Content -Path $cachePath -Encoding UTF8
    }
}
'@

        Add-Content -Path $resilienceFile -Value $diffFunction -Encoding UTF8
        Write-Host "  [OK] Added Get-DifferentialContext + Save-ReviewedCommit to resilience.ps1" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] Get-DifferentialContext already exists in resilience.ps1" -ForegroundColor DarkGray
    }
} else {
    Write-Host "  [WARN] resilience.ps1 not found" -ForegroundColor Yellow
}

# ── 4. Update convergence-loop.ps1 with differential review dispatch ──

$convergenceFile = Join-Path $GsdGlobalDir "scripts\convergence-loop.ps1"
if (Test-Path $convergenceFile) {
    $loopContent = Get-Content $convergenceFile -Raw

    if ($loopContent -like "*Get-DifferentialContext*") {
        Write-Host "  [SKIP] convergence-loop.ps1 already has differential review" -ForegroundColor DarkGray
    } else {
        # Find the code-review phase and prepend differential logic
        $reviewMarker = 'Local-ResolvePrompt "$GlobalDir\prompts\claude\code-review'
        if ($loopContent -like "*$reviewMarker*") {
            $idx = $loopContent.IndexOf($reviewMarker)
            # Find the $prompt = line that contains this
            $lineStart = $loopContent.LastIndexOf("`n", $idx) + 1
            $lineEnd = $loopContent.IndexOf("`n", $idx)
            $originalLine = $loopContent.Substring($lineStart, $lineEnd - $lineStart).Trim()

            $diffBlock = @'

        # ── Differential Review Check ──
        $useDiffReview = $false
        if (Get-Command Get-DifferentialContext -ErrorAction SilentlyContinue) {
            $diffCtx = Get-DifferentialContext -GsdDir $GsdDir -GlobalDir $GlobalDir -Iteration $Iteration -RepoRoot $RepoRoot
            if ($diffCtx.UseDifferential -and $diffCtx.ChangedFiles.Count -gt 0) {
                Write-Host "  [DIFF] Differential review: $($diffCtx.ChangedFiles.Count) files changed" -ForegroundColor Cyan
                $diffPromptPath = "$GlobalDir\prompts\claude\code-review-differential.md"
                if (Test-Path $diffPromptPath) {
                    $prompt = Local-ResolvePrompt $diffPromptPath $Iteration $Health
                    $prompt = $prompt.Replace("{{DIFF_CONTENT}}", $diffCtx.DiffContent)
                    $prompt = $prompt.Replace("{{CHANGED_FILES}}", ($diffCtx.ChangedFiles -join "`n"))
                    $useDiffReview = $true
                }
            } elseif ($diffCtx.UseDifferential -and $diffCtx.ChangedFiles.Count -eq 0) {
                Write-Host "  [DIFF] No files changed since last review -- skipping code-review phase" -ForegroundColor DarkGray
                # Still need to save checkpoint
                if (Get-Command Save-ReviewedCommit -ErrorAction SilentlyContinue) {
                    Save-ReviewedCommit -GsdDir $GsdDir -Iteration $Iteration
                }
            } else {
                Write-Host "  [DIFF] Full review: $($diffCtx.Reason)" -ForegroundColor DarkGray
            }
        }
        if (-not $useDiffReview) {
'@

            $afterBlock = @'

        }  # end differential review fallback

        # Save reviewed commit for next differential
        if (Get-Command Save-ReviewedCommit -ErrorAction SilentlyContinue) {
            Save-ReviewedCommit -GsdDir $GsdDir -Iteration $Iteration
        }
'@

            # Insert before the prompt line
            $before = $loopContent.Substring(0, $lineStart)
            $after = $loopContent.Substring($lineStart)

            # Find the end of the code-review result handling (next phase marker)
            $nextPhaseMarker = "# Throttle between phases"
            $nextPhaseIdx = $after.IndexOf($nextPhaseMarker)
            if ($nextPhaseIdx -lt 0) {
                $nextPhaseMarker = "Start-Sleep"
                $nextPhaseIdx = $after.IndexOf($nextPhaseMarker)
            }

            if ($nextPhaseIdx -gt 0) {
                $reviewBlock = $after.Substring(0, $nextPhaseIdx)
                $restAfter = $after.Substring($nextPhaseIdx)
                $newContent = $before + $diffBlock + "`n" + $reviewBlock + $afterBlock + "`n        " + $restAfter
                Set-Content -Path $convergenceFile -Value $newContent -Encoding UTF8
                Write-Host "  [OK] Updated convergence-loop.ps1 with differential review" -ForegroundColor Green
            } else {
                Write-Host "  [WARN] Could not find code-review end boundary -- appending note" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  [WARN] Could not find code-review prompt line in convergence-loop.ps1" -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "  [WARN] convergence-loop.ps1 not found" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  [DIFFERENTIAL] Installation complete." -ForegroundColor Green
Write-Host "  Config: global-config.json -> differential_review" -ForegroundColor DarkGray
Write-Host "  Prompt: prompts/claude/code-review-differential.md" -ForegroundColor DarkGray
Write-Host "  Functions: Get-DifferentialContext, Save-ReviewedCommit" -ForegroundColor DarkGray
Write-Host "  Pipeline: convergence-loop.ps1 (differential-aware review)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  To disable: Set differential_review.enabled = false in global-config.json" -ForegroundColor DarkGray
Write-Host ""
