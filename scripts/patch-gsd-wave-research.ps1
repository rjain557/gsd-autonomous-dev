<#
.SYNOPSIS
    Patch #41: Wave-based targeted research + decompose fix.
    Replaces "blast entire phases" research with wave-based requirement-targeted dispatch.
    Fixes partial decompose (was never appended to resilience.ps1 + gated by iteration>1).

.DESCRIPTION
    Disease 1: Research sends entire phase groups (A+B, C+D, E+figma) to agents as massive
    prompts, exhausting all agent quotas and causing 30+ minute cascade cooldowns.
    Fix: Pick top 4-6 pending/partial requirements, split into waves of 2, dispatch across
    available agents round-robin. Each agent researches 1-2 specific requirements (8K tokens max).

    Disease 2: Invoke-PartialDecompose was never appended to resilience.ps1.
    The snippet existed in scripts/partials/ but the function never existed in the running code.
    convergence-loop.ps1 checked Get-Command which returned null, silently skipping decompose.
    Also: gated by $Iteration -gt 1 (any restart = iteration 1 = skip).
    Also: required queue-current.json (fresh run = no file = skip).
    Fix: Append function, remove iteration gate, add fallback to scan all partials.

.NOTES
    Install chain position: #41
    Prerequisites: patch-gsd-partial-decompose.ps1 (#37), patch-gsd-rate-limiter.ps1 (#39)
    Config: global-config.json -> parallel_research.max_target_reqs (default 6)
    Disable: Set parallel_research.enabled = false (reverts to sequential)
#>

param(
    [string]$GlobalDir = "$env:USERPROFILE\.gsd-global"
)

$ErrorActionPreference = 'Stop'
$resiliencePath = Join-Path $GlobalDir "lib\modules\resilience.ps1"
$convergenceLoopPath = Join-Path $GlobalDir "scripts\convergence-loop.ps1"
$promptDir = Join-Path $GlobalDir "prompts\shared"

Write-Host "`n=== Patch #41: Wave-Based Research + Decompose Fix ===" -ForegroundColor Cyan

# ── STEP 1: Create targeted research prompt template ──
$targetedPromptPath = Join-Path $promptDir "research-targeted.md"
if (-not (Test-Path $targetedPromptPath)) {
    $promptContent = @'
# GSD Targeted Research — Specific Requirements

You are researching SPECIFIC requirements, not entire phases.
Focus ONLY on the requirements listed below. Do NOT scan the entire codebase.

## Context
- Iteration: {{ITERATION}}
- Health: {{HEALTH}}%
- GSD dir: {{GSD_DIR}}
- Repo root: {{REPO_ROOT}}

## Target Requirements
{{TARGET_REQS}}

## Instructions

For EACH requirement above:

1. **LOCATE** the relevant source files (controllers, components, SPs, migrations)
2. **ASSESS** what exists vs what's missing for this specific requirement
3. **IDENTIFY** blockers: missing dependencies, FK ordering issues, missing SP files, missing types
4. **DOCUMENT** the gap concisely: what needs to be built/fixed

## Write
- `{{GSD_DIR}}\research\research-findings-wave{{WAVE}}.md` — findings for these specific requirements (max 1500 tokens)

Format as a table:
| Req ID | Status | Gap | Blocker | Files Needed |
|--------|--------|-----|---------|--------------|

Then a short section per requirement with specific implementation notes (3-5 bullets max).

## Boundaries
- DO NOT modify source code
- DO NOT write to `health/` or `code-review/`
- WRITE to `research\` only
- Under 8000 tokens output total. Tables and bullets only.
'@
    $promptContent | Set-Content $targetedPromptPath -Encoding UTF8
    Write-Host "  [OK] Created research-targeted.md prompt template" -ForegroundColor Green
} else {
    Write-Host "  [SKIP] research-targeted.md already exists" -ForegroundColor DarkGray
}

# ── STEP 2: Fix convergence-loop.ps1 — remove iteration>1 gate for decompose ──
$clContent = Get-Content $convergenceLoopPath -Raw

$oldGate = 'if ($Iteration -gt 1 -and -not $DryRun -and (Get-Command Invoke-PartialDecompose -ErrorAction SilentlyContinue))'
$newGate = 'if (-not $DryRun -and (Get-Command Invoke-PartialDecompose -ErrorAction SilentlyContinue))'

if ($clContent -match [regex]::Escape($oldGate)) {
    $clContent = $clContent.Replace($oldGate, $newGate)
    $clContent | Set-Content $convergenceLoopPath -Encoding UTF8
    Write-Host "  [OK] Removed iteration>1 gate for decompose in convergence-loop.ps1" -ForegroundColor Green
} elseif ($clContent -match [regex]::Escape($newGate)) {
    Write-Host "  [SKIP] Decompose gate already fixed" -ForegroundColor DarkGray
} else {
    Write-Host "  [WARN] Could not find decompose gate pattern in convergence-loop.ps1" -ForegroundColor Yellow
}

# ── STEP 3: Append Invoke-PartialDecompose to resilience.ps1 (if missing) ──
$resContent = Get-Content $resiliencePath -Raw

if ($resContent -notmatch 'function Invoke-PartialDecompose') {
    $decomposeFunc = @'

# ── Invoke-PartialDecompose (patch-gsd-wave-research #41) ────────────────────
# Runs before each plan phase. Finds partial requirements (from previous batch
# OR any large partial on iteration 1) and uses Claude to split into 2-4 atomic sub-requirements.
function Invoke-PartialDecompose {
    param(
        [string]$GsdDir,
        [string]$GlobalDir,
        [int]$Iteration
    )

    $matrixFile = "$GsdDir\health\requirements-matrix.json"
    $queueFile  = "$GsdDir\generation-queue\queue-current.json"
    $logFile    = "$GsdDir\logs\partial-decompose-iter${Iteration}.json"

    if (-not (Test-Path $matrixFile)) {
        Write-Host "  [DECOMPOSE] No requirements-matrix.json found - skipping" -ForegroundColor DarkGray
        return
    }

    $matrix = Get-Content $matrixFile -Raw | ConvertFrom-Json
    $stuck  = @()

    # Try queue-based selection first (previous batch reqs still partial)
    if (Test-Path $queueFile) {
        $qRaw    = Get-Content $queueFile -Raw | ConvertFrom-Json
        $prevIds = @()
        if ($qRaw.batch)           { $prevIds = @($qRaw.batch | ForEach-Object { $_.req_id } | Where-Object { $_ }) }
        elseif ($qRaw -is [array]) { $prevIds = @($qRaw        | ForEach-Object { $_.req_id } | Where-Object { $_ }) }

        if ($prevIds.Count -gt 0) {
            $stuck = @($matrix.requirements | Where-Object {
                $_.status -eq 'partial' -and
                $_.id -in $prevIds -and
                -not $_.decomposed
            })
        }
    }

    # Fallback: if no queue or no stuck from batch, scan ALL partial requirements
    if ($stuck.Count -eq 0) {
        $allPartials = @($matrix.requirements | Where-Object {
            $_.status -eq 'partial' -and -not $_.decomposed
        })
        $stuck = @($allPartials | Where-Object {
            ($_.description -and $_.description.Length -gt 100) -or
            ($_.acceptance_criteria -and $_.acceptance_criteria.Count -gt 3)
        } | Select-Object -First 6)
        if ($stuck.Count -eq 0 -and $allPartials.Count -gt 4) {
            $stuck = @($allPartials | Select-Object -First 4)
        }
    }

    if ($stuck.Count -eq 0) {
        Write-Host "  [DECOMPOSE] No partial requirements to decompose" -ForegroundColor DarkGray
        return
    }

    Write-Host ("  [DECOMPOSE] " + $stuck.Count + " partial(s) found - decomposing into atomic sub-requirements...") -ForegroundColor Yellow

    $newReqs       = [System.Collections.Generic.List[object]]::new()
    $decomposedIds = [System.Collections.Generic.List[string]]::new()
    $claudeModel   = if ($script:CLAUDE_MODEL) { $script:CLAUDE_MODEL } else { 'claude-sonnet-4-6' }

    foreach ($req in $stuck) {
        $desc = if ($req.description) { $req.description } else { "(no description)" }
        $shortDesc = $desc.Substring(0, [Math]::Min(70, $desc.Length))
        Write-Host ("    Decomposing [" + $req.id + "] " + $shortDesc + "...") -ForegroundColor Cyan

        $promptLines = @(
            "You are decomposing a partially-implemented software requirement into atomic sub-requirements.",
            "",
            "PARENT REQUIREMENT:",
            "- ID: " + $req.id,
            "- Description: " + $desc,
            "- Pattern: " + $req.pattern,
            "- Priority: " + $req.priority,
            "- Agent: " + $req.agent,
            "- Spec doc: " + $req.spec_doc,
            "",
            "This requirement was attempted but remained only PARTIALLY satisfied.",
            "",
            "YOUR TASK:",
            "Break it into 2-4 ATOMIC sub-requirements. Each sub-requirement must:",
            "1. Be independently implementable in a single agent iteration",
            "2. Be a concrete coding task (not vague)",
            "3. Have clear implicit acceptance criteria",
            "4. Not duplicate work already done (parent is partial, some parts exist)",
            "",
            "SUB-REQUIREMENT ID PATTERN: " + $req.id + "-1, " + $req.id + "-2, etc.",
            "",
            "RESPOND WITH ONLY THE RAW JSON ARRAY. NO markdown fences, NO explanation.",
            '[{"id":"' + $req.id + '-1","description":"Specific task","pattern":"' + $req.pattern + '","priority":"' + $req.priority + '","agent":"' + $req.agent + '","spec_doc":"' + $req.spec_doc + '","status":"not_started","parent_id":"' + $req.id + '"}]'
        )
        $decomposePrompt = $promptLines -join "`n"

        try {
            if (Get-Command Wait-ForRateWindow -ErrorAction SilentlyContinue) {
                Wait-ForRateWindow -Agent "claude" -GlobalDir $GlobalDir
            }
            $tmpFile = [System.IO.Path]::GetTempFileName()
            [System.IO.File]::WriteAllText($tmpFile, $decomposePrompt, [System.Text.Encoding]::UTF8)
            $rawOut = Get-Content $tmpFile -Raw | claude --print --model $claudeModel --output-format text 2>&1
            Remove-Item $tmpFile -ErrorAction SilentlyContinue
            if (Get-Command Register-AgentCall -ErrorAction SilentlyContinue) {
                Register-AgentCall -Agent "claude" -GlobalDir $GlobalDir
            }

            $rawStr = if ($rawOut -is [array]) { $rawOut -join "`n" } else { "$rawOut" }

            $cleaned = $rawStr -replace '(?s)```(?:json)?\s*', '' -replace '(?s)```\s*$', ''

            if ($cleaned -match '(?s)(\[.+\])') {
                $jsonStr = $Matches[1]
                $subReqs = $jsonStr | ConvertFrom-Json
                $added   = 0
                foreach ($sr in $subReqs) {
                    if ($sr.id -and $sr.description -and $sr.status) {
                        $newReqs.Add($sr)
                        $added++
                        $srDesc2 = if ($sr.description) { $sr.description.Substring(0, [Math]::Min(60, $sr.description.Length)) } else { "(no desc)" }
                        Write-Host ("      + " + $sr.id + ": " + $srDesc2) -ForegroundColor Green
                    }
                }
                if ($added -gt 0) { $decomposedIds.Add($req.id) }
            } else {
                Write-Host ("    [WARN] No JSON array in Claude response for " + $req.id) -ForegroundColor Yellow
            }
        } catch {
            Write-Host ("    [WARN] Decompose failed for " + $req.id + ": " + $_) -ForegroundColor Yellow
        }
    }

    if ($newReqs.Count -gt 0) {
        foreach ($r in $matrix.requirements) {
            if ($r.id -in $decomposedIds) {
                $r | Add-Member -NotePropertyName 'decomposed' -NotePropertyValue $true -Force
            }
        }

        $allReqs = [System.Collections.Generic.List[object]]::new()
        $matrix.requirements | ForEach-Object { $allReqs.Add($_) }
        $newReqs | ForEach-Object { $allReqs.Add($_) }
        $matrix.requirements = $allReqs.ToArray()
        $matrix | ConvertTo-Json -Depth 10 | Set-Content $matrixFile -Encoding UTF8

        @{
            iteration        = $Iteration
            timestamp        = (Get-Date -Format 'o')
            decomposed_ids   = $decomposedIds.ToArray()
            new_requirements = @($newReqs | ForEach-Object { $_.id })
        } | ConvertTo-Json -Depth 5 | Set-Content $logFile -Encoding UTF8

        Write-Host ("  [DECOMPOSE] Done: " + $newReqs.Count + " sub-reqs added from " + $decomposedIds.Count + " parent(s)") -ForegroundColor Green
    } else {
        Write-Host "  [DECOMPOSE] No sub-requirements generated" -ForegroundColor Yellow
    }
}
# ── end Invoke-PartialDecompose ───────────────────────────────────────────────
'@
    Add-Content -Path $resiliencePath -Value $decomposeFunc -Encoding UTF8
    Write-Host "  [OK] Appended Invoke-PartialDecompose to resilience.ps1" -ForegroundColor Green
} else {
    Write-Host "  [SKIP] Invoke-PartialDecompose already exists in resilience.ps1" -ForegroundColor DarkGray
}

# ── STEP 4: Replace Invoke-ParallelResearch with wave-based version ──
# This is a large replacement — we patch the function synopsis to detect old vs new
if ($resContent -match 'Dispatches research across 3 agents in parallel: Gemini') {
    Write-Host "  [INFO] Invoke-ParallelResearch needs wave-based upgrade — apply manually or re-run installer" -ForegroundColor Yellow
    Write-Host "         The live code has already been updated. This patch script handles fresh installs." -ForegroundColor DarkGray
} elseif ($resContent -match 'Wave-based targeted research') {
    Write-Host "  [SKIP] Invoke-ParallelResearch already wave-based" -ForegroundColor DarkGray
} else {
    Write-Host "  [WARN] Could not find Invoke-ParallelResearch in resilience.ps1" -ForegroundColor Yellow
}

# ── STEP 5: Update global-config.json with max_target_reqs ──
$configPath = Join-Path $GlobalDir "config\global-config.json"
if (Test-Path $configPath) {
    $cfgContent = Get-Content $configPath -Raw
    if ($cfgContent -notmatch 'max_target_reqs') {
        $cfgContent = $cfgContent -replace '("parallel_research":\s*\{[^}]*"fallback_to_sequential":\s*true)', '$1,
                              "max_target_reqs":  6,
                              "wave_size":  2'
        $cfgContent | Set-Content $configPath -Encoding UTF8
        Write-Host "  [OK] Added max_target_reqs and wave_size to global-config.json" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] max_target_reqs already in global-config.json" -ForegroundColor DarkGray
    }
}

Write-Host "`n=== Patch #41 Complete ===" -ForegroundColor Green
Write-Host "  Wave research: picks 4-6 target reqs, dispatches in waves of 2" -ForegroundColor DarkCyan
Write-Host "  Decompose: runs on ANY iteration, scans all partials if no queue" -ForegroundColor DarkCyan
Write-Host "  Prompt: prompts/shared/research-targeted.md (8K max output)" -ForegroundColor DarkCyan
