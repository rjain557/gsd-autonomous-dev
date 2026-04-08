<#
.SYNOPSIS
    GSD 7-Model Optimization Patch (Script #36)
    Maximizes throughput, quality, and cost-efficiency across all 7 LLM agents.

.DESCRIPTION
    Implements 12 targeted optimizations:

    1.  max_concurrent: 3 -> 7  (all 7 agents execute sub-tasks simultaneously)
    2.  max_batch: 8 -> 14      (calibrated for 7-agent parallel execution)
    3.  Parallel research       (Gemini->PhaseA+B, DeepSeek->PhaseC+D, Kimi->PhaseE+Figma)
    4.  Wire Get-BestAgentForPhase into monolithic execute path
    5.  Plan reads all 4 research outputs (pattern-analysis + tech-decisions)
    6.  Acceptance test hard-blocking on file_exists + pattern_match + build_check
    7.  5-partition code review  (add DeepSeek/Frontend, Kimi/Integration+Figma)
    8.  DeepSeek as 3rd council reviewer (via council.reviewers in agent-map.json)
    9.  Remove research auto-skip (parallel research is cheap; always run)
    10. Figma-First mode for UI batches in monolithic execute
    11. Adaptive wave cooldown   (3s clean / 30s quota-pressure detected)
    12. Complexity-based agent routing (low->DeepSeek, medium->Kimi/Codex, high->Claude/Codex)

.INSTALL_ORDER
    Run after all existing patches (after patch-gsd-maintenance-mode.ps1, script #35).

.USAGE
    powershell -ExecutionPolicy Bypass -File patch-gsd-7model-optimize.ps1
#>

param([string]$UserHome = $env:USERPROFILE)
$ErrorActionPreference = "Stop"

$GsdGlobalDir = Join-Path $UserHome ".gsd-global"

if (-not (Test-Path "$GsdGlobalDir\lib\modules\resilience.ps1")) {
    Write-Host "[XX] GSD not installed. Run all prior installers first." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  GSD 7-Model Optimization Patch (Script #36)" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

# ── 1. agent-map.json: max_concurrent 7, council.reviewers ──────────────────

$agentMapPath = Join-Path $GsdGlobalDir "config\agent-map.json"
if (Test-Path $agentMapPath) {
    $agentMap = Get-Content $agentMapPath -Raw | ConvertFrom-Json

    if ([int]$agentMap.execute_parallel.max_concurrent -lt 7) {
        $agentMap.execute_parallel.max_concurrent = 7
        Write-Host "  [OK] execute_parallel.max_concurrent -> 7" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] max_concurrent already >= 7" -ForegroundColor DarkGray
    }

    if (-not $agentMap.council) {
        $agentMap | Add-Member -NotePropertyName "council" -NotePropertyValue ([PSCustomObject]@{
            reviewers = @("codex", "gemini", "deepseek")
        })
        Write-Host "  [OK] Added council.reviewers = [codex, gemini, deepseek]" -ForegroundColor Green
    } elseif (@($agentMap.council.reviewers) -notcontains "deepseek") {
        $agentMap.council.reviewers = @($agentMap.council.reviewers) + "deepseek"
        Write-Host "  [OK] Added deepseek to council.reviewers" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] council.reviewers already includes deepseek" -ForegroundColor DarkGray
    }

    $agentMap | ConvertTo-Json -Depth 10 | Set-Content $agentMapPath -Encoding UTF8
} else {
    Write-Host "  [WARN] agent-map.json not found at $agentMapPath" -ForegroundColor Yellow
}

# ── 2. global-config.json: batch size, acceptance tests, partitions, research ──

$configPath = Join-Path $GsdGlobalDir "config\global-config.json"
if (Test-Path $configPath) {
    $config = Get-Content $configPath -Raw | ConvertFrom-Json
    $dirty  = $false

    # Rec 2: batch_size_max 8->14
    if ([int]$config.batch_size_max -lt 14) {
        $config.batch_size_max = 14; $dirty = $true
        Write-Host "  [OK] batch_size_max -> 14" -ForegroundColor Green
    }

    # Rec 2: smart_batch max_batch 8->14
    if ($config.speed_optimizations.smart_batch_sizing) {
        if ([int]$config.speed_optimizations.smart_batch_sizing.max_batch -lt 14) {
            $config.speed_optimizations.smart_batch_sizing.max_batch = 14; $dirty = $true
            Write-Host "  [OK] smart_batch_sizing.max_batch -> 14" -ForegroundColor Green
        }
    }

    # Rec 9: disable research auto-skip
    if ($config.speed_optimizations.conditional_research_skip.enabled -ne $false) {
        $config.speed_optimizations.conditional_research_skip.enabled = $false; $dirty = $true
        Write-Host "  [OK] conditional_research_skip disabled (parallel research always runs)" -ForegroundColor Green
    }

    # Rec 6: acceptance_tests block_on_failure + block_types
    if (-not $config.acceptance_tests.block_on_failure) {
        $config.acceptance_tests.block_on_failure = $true; $dirty = $true
        Write-Host "  [OK] acceptance_tests.block_on_failure -> true" -ForegroundColor Green
    }
    if (-not $config.acceptance_tests.block_types) {
        $config.acceptance_tests | Add-Member -NotePropertyName "block_types" `
            -NotePropertyValue @("file_exists","pattern_match","build_check") -Force
        $dirty = $true
        Write-Host "  [OK] acceptance_tests.block_types = [file_exists, pattern_match, build_check]" -ForegroundColor Green
    }

    # Rec 7: 5-partition review
    if ([int]$config.partitioned_code_review.partition_count -lt 5) {
        $config.partitioned_code_review.partition_count = 5; $dirty = $true
        Write-Host "  [OK] partitioned_code_review.partition_count -> 5" -ForegroundColor Green
    }
    $reviewAgents = @($config.partitioned_code_review.agents)
    $addedAgents  = @()
    foreach ($a in @("deepseek","kimi")) {
        if ($reviewAgents -notcontains $a) { $reviewAgents += $a; $addedAgents += $a }
    }
    if ($addedAgents.Count -gt 0) {
        $config.partitioned_code_review.agents = $reviewAgents; $dirty = $true
        Write-Host "  [OK] partitioned_code_review.agents += $($addedAgents -join ', ')" -ForegroundColor Green
    }

    # Rec 3: parallel_research config
    if (-not $config.parallel_research) {
        $config | Add-Member -NotePropertyName "parallel_research" -NotePropertyValue ([PSCustomObject]@{
            enabled              = $true
            timeout_minutes      = 20
            fallback_to_sequential = $true
            agents = @(
                [PSCustomObject]@{ agent="gemini";   phases=@("A","B"); prompt="research-phases-ab.md";     prompt_dir="gemini" }
                [PSCustomObject]@{ agent="deepseek"; phases=@("C","D"); prompt="research-phases-cd.md";     prompt_dir="shared" }
                [PSCustomObject]@{ agent="kimi";     phases=@("E","figma"); prompt="research-phases-e-figma.md"; prompt_dir="shared" }
            )
        })
        $dirty = $true
        Write-Host "  [OK] Added parallel_research config block" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] parallel_research already exists" -ForegroundColor DarkGray
    }

    # Rec 12: complexity_routing config
    if (-not $config.complexity_routing) {
        $config | Add-Member -NotePropertyName "complexity_routing" -NotePropertyValue ([PSCustomObject]@{
            enabled = $true
            low     = [PSCustomObject]@{ criteria=@("crud","stored_procedure","utility","config","sql_view","seed_data"); preferred_agents=@("deepseek","minimax") }
            medium  = [PSCustomObject]@{ criteria=@("feature","ui_component","api_endpoint","auth","form","validation");  preferred_agents=@("kimi","codex") }
            high    = [PSCustomObject]@{ criteria=@("compliance","cross_cutting","performance","security","complex_logic","hipaa","pci","gdpr"); preferred_agents=@("claude","codex") }
        })
        $dirty = $true
        Write-Host "  [OK] Added complexity_routing config block" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] complexity_routing already exists" -ForegroundColor DarkGray
    }

    if ($dirty) {
        $config | ConvertTo-Json -Depth 10 | Set-Content $configPath -Encoding UTF8
        Write-Host "  [OK] global-config.json saved" -ForegroundColor Green
    }
} else {
    Write-Host "  [WARN] global-config.json not found" -ForegroundColor Yellow
}

# ── 3. Create parallel research prompt templates ─────────────────────────────

$promptFiles = @(
    @{
        Path    = "$GsdGlobalDir\prompts\gemini\research-phases-ab.md"
        Marker  = "PARALLEL RESEARCHER.*Phase A"
        Content = @'
# GSD Research - Phase A+B: Architecture & Database (Gemini)

You are a PARALLEL RESEARCHER. Focus exclusively on **Phase A (Architecture)** and **Phase B (Database)**.
Two other agents are researching Phases C-E and Figma simultaneously. Do NOT overlap with them.

## Context
- Iteration: {{ITERATION}}
- Health: {{HEALTH}}%
- GSD dir: {{GSD_DIR}}
- Repo root: {{REPO_ROOT}}
{{INTERFACE_CONTEXT}}

## Your Focus: Phase A (Architecture) + Phase B (Database)

### Read
1. `docs/` — all Phase A and Phase B spec documents only
2. `database/` or `db/` — existing SQL migration files, stored procedures, seed scripts
3. `{{GSD_DIR}}\health\requirements-matrix.json` — Phase A and Phase B requirements only
4. Backend project root (`.sln`, `appsettings.json`, Program.cs, startup configuration)

### Do

1. **ANALYZE Phase A — Architecture:** service boundaries, auth approach, infrastructure, DI config, compliance hooks
2. **ANALYZE Phase B — Database:** tables, SPs, FK dependency graph, index strategy, migration order
3. **IDENTIFY gaps:** which SPs are missing, which tables lack migration scripts, FK ordering violations

## Write
- `{{GSD_DIR}}\research\research-findings-ab.md`
- `{{GSD_DIR}}\research\dependency-map.json`

## Boundaries
- DO NOT modify source code. WRITE to research\ only. Under 3000 tokens. Tables/bullets only.
'@
    },
    @{
        Path    = "$GsdGlobalDir\prompts\shared\research-phases-cd.md"
        Marker  = "PARALLEL RESEARCHER.*Phase C"
        Content = @'
# GSD Research - Phase C+D: API Contracts & Frontend (DeepSeek)

You are a PARALLEL RESEARCHER. Focus on **Phase C (API/Backend)** and **Phase D (Frontend/UI)**.

## Context
- Iteration: {{ITERATION}}
- Health: {{HEALTH}}%
- GSD dir: {{GSD_DIR}}
- Repo root: {{REPO_ROOT}}

### Read
1. docs/ — Phase C and Phase D spec documents only
2. `{{GSD_DIR}}\health\requirements-matrix.json` — Phase C and Phase D requirements only
3. Existing API controllers, services, repositories
4. Existing React components and pages

### Do
1. **Phase C:** endpoint inventory, auth per endpoint, validation rules, missing controllers
2. **Phase D:** component inventory, state management, API integration points, missing components
3. **MAP gaps:** missing endpoints, missing React components, undefined service interfaces

## Write
- `{{GSD_DIR}}\research\research-findings-cd.md`
- `{{GSD_DIR}}\research\pattern-analysis.md`

## Boundaries
- DO NOT modify source code. WRITE to research\ only. Under 3000 tokens. Tables/bullets only.
'@
    },
    @{
        Path    = "$GsdGlobalDir\prompts\shared\research-phases-e-figma.md"
        Marker  = "PARALLEL RESEARCHER.*Phase E"
        Content = @'
# GSD Research - Phase E + Figma: Integration & UI Fidelity (Kimi)

You are a PARALLEL RESEARCHER. Focus on **Phase E (Integration)** and **all Figma deliverables**.

## Context
- Iteration: {{ITERATION}}
- Health: {{HEALTH}}%
- GSD dir: {{GSD_DIR}}
- Repo root: {{REPO_ROOT}}
{{INTERFACE_CONTEXT}}

### Read
1. docs/ — Phase E spec documents only
2. `{{FIGMA_PATH}}` — ALL Figma analysis files
3. `{{GSD_DIR}}\specs\figma-mapping.md`
4. `{{GSD_DIR}}\health\requirements-matrix.json` — Phase E + UI requirements
5. Frontend src/ directory

### Do
1. **Phase E:** end-to-end workflow gaps, integration test scenarios, deployment config, performance requirements
2. **Figma audit:** component inventory, implementation gaps, state coverage, design token violations, responsive gaps, interaction states
3. **Component-to-file mapping:** Figma frame -> .tsx file, missing components list

## Write
- `{{GSD_DIR}}\research\research-findings-e-figma.md`
- `{{GSD_DIR}}\research\tech-decisions.md`
- UPDATE `{{GSD_DIR}}\specs\figma-mapping.md`

## Boundaries
- DO NOT modify source code. WRITE to research\ and specs\figma-mapping.md only. Under 3000 tokens.
'@
    }
)

foreach ($pf in $promptFiles) {
    if (Test-Path $pf.Path) {
        $existing = Get-Content $pf.Path -Raw
        if ($existing -match $pf.Marker) {
            Write-Host "  [SKIP] $([System.IO.Path]::GetFileName($pf.Path)) already updated" -ForegroundColor DarkGray
            continue
        }
    }
    $pf.Content | Set-Content $pf.Path -Encoding UTF8
    Write-Host "  [OK] Created $([System.IO.Path]::GetFileName($pf.Path))" -ForegroundColor Green
}

# ── 4. Create DeepSeek council review prompt ─────────────────────────────────

$deepseekCouncilPath = "$GsdGlobalDir\prompts\council\deepseek-review.md"
if (-not (Test-Path $deepseekCouncilPath)) {
    @'
# LLM Council Review -- Code Patterns & Maintainability (DeepSeek)

You are 1 of 3 independent reviewers in a multi-agent council. Be HONEST -- do not rubber-stamp.

## Context
- Health: {{HEALTH}}% | Iteration: {{ITERATION}}
- GSD dir: {{GSD_DIR}}

## Read
1. `{{GSD_DIR}}\health\requirements-matrix.json`
2. Source code (focus on recently changed files)

## Review Focus
1. **Code Patterns**: Dapper-only, repository pattern, functional React hooks consistency
2. **Duplication**: Logic that should be extracted to shared utilities
3. **Completeness**: All requirements implemented (not stubbed with TODO)?
4. **Security**: SQL injection, missing [Authorize], hardcoded secrets, PII in logs?
5. **Audit**: INSERT/UPDATE/DELETE operations logged to audit table?

## Output Format (max 2000 tokens)
Return ONLY a JSON object:
```json
{
  "vote": "approve|concern|block",
  "confidence": 0-100,
  "findings": ["finding 1 (file:line)"],
  "strengths": ["strength 1"],
  "summary": "1-2 sentence summary"
}
```
'@ | Set-Content $deepseekCouncilPath -Encoding UTF8
    Write-Host "  [OK] Created deepseek-review.md council prompt" -ForegroundColor Green
} else {
    Write-Host "  [SKIP] deepseek-review.md already exists" -ForegroundColor DarkGray
}

# ── 5. Update partition D + E prompts (stub -> spec-phase-aligned) ────────────

$partitionDPath = "$GsdGlobalDir\prompts\shared\code-review-partition-D.md"
$partitionDContent = Get-Content $partitionDPath -Raw -ErrorAction SilentlyContinue
if ($partitionDContent -notmatch "Phase D.*Frontend|DeepSeek") {
    @'
# Code Review - Partition D: Frontend/UI (Phase D) -- DeepSeek

You are reviewing **Partition D**: Phase D frontend/UI components.

## Your Assigned Requirements
{{PARTITION_REQUIREMENTS}}

## Your Assigned Files
{{PARTITION_FILES}}

## Spec Validation (Phase D)
{{SPEC_PATHS}}
Check: component exists, form fields present, API calls correct, state management per spec.

## Figma Validation
{{FIGMA_PATHS}}
Check: component structure, all elements present, layout/spacing, interaction states, design tokens.

## Code Quality
- Functional components + hooks only | Error boundaries | ARIA labels | Loading/error/empty states

## Output
1. Update requirements-matrix.json: satisfied / partial / not_started
2. Write .gsd/code-review/partition-D-review.md (max 80 lines, table format)
3. Write .gsd/code-review/partition-D-drift.md (max 30 lines)

## Token Budget: 3000 tokens max. Tables and bullets only.
'@ | Set-Content $partitionDPath -Encoding UTF8
    Write-Host "  [OK] Updated partition-D prompt (Phase D / DeepSeek)" -ForegroundColor Green
} else {
    Write-Host "  [SKIP] partition-D already updated" -ForegroundColor DarkGray
}

$partitionEPath = "$GsdGlobalDir\prompts\shared\code-review-partition-E.md"
$partitionEContent = Get-Content $partitionEPath -Raw -ErrorAction SilentlyContinue
if ($partitionEContent -notmatch "Phase E.*Integration|Kimi") {
    @'
# Code Review - Partition E: Integration, Compliance & Figma Fidelity (Phase E) -- Kimi

You are reviewing **Partition E**: Phase E integration/compliance and full Figma fidelity audit.

## Your Assigned Requirements
{{PARTITION_REQUIREMENTS}}

## Your Assigned Files
{{PARTITION_FILES}}

## Spec Validation (Phase E)
{{SPEC_PATHS}}
Check: end-to-end workflows complete, integration points wired, deployment config present.

## Figma Fidelity Audit (ALL partitions)
{{FIGMA_PATHS}}
Check: missing components, state gaps (loading/error/empty), responsive gaps, color system, typography.

## Compliance Review
- HIPAA: PHI encrypted, audit log on every PHI access | SOC2: RBAC, change trail
- PCI: Card data tokenized, never stored raw | GDPR: Consent tracked, export/delete endpoints

## Output
1. Update requirements-matrix.json: satisfied / partial / not_started
2. Write .gsd/code-review/partition-E-review.md (max 80 lines)
3. Write .gsd/code-review/partition-E-drift.md (max 30 lines)

## Token Budget: 3000 tokens max. Tables and bullets only.
'@ | Set-Content $partitionEPath -Encoding UTF8
    Write-Host "  [OK] Updated partition-E prompt (Phase E / Kimi)" -ForegroundColor Green
} else {
    Write-Host "  [SKIP] partition-E already updated" -ForegroundColor DarkGray
}

# ── 6. Update plan.md: add research outputs + complexity field ────────────────

$planPath = "$GsdGlobalDir\prompts\claude\plan.md"
if (Test-Path $planPath) {
    $planContent = Get-Content $planPath -Raw
    if ($planContent -notmatch "pattern-analysis\.md") {
        $planContent = $planContent.Replace(
            "3. {{GSD_DIR}}\research\research-findings.md (if exists, from Codex research phase)",
            "3. {{GSD_DIR}}\research\research-findings.md (merged parallel research findings)"
        )
        $planContent = $planContent.Replace(
            "4. {{GSD_DIR}}\research\dependency-map.json (if exists)",
            "4. {{GSD_DIR}}\research\dependency-map.json (if exists)`n5. {{GSD_DIR}}\research\pattern-analysis.md (if exists -- API + component patterns)`n6. {{GSD_DIR}}\research\tech-decisions.md (if exists -- UI/UX decisions, component strategy)"
        )
        $planContent | Set-Content $planPath -Encoding UTF8
        Write-Host "  [OK] plan.md: added pattern-analysis.md + tech-decisions.md to Read section" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] plan.md already reads pattern-analysis.md" -ForegroundColor DarkGray
    }

    $planContent = Get-Content $planPath -Raw
    if ($planContent -notmatch '"complexity"') {
        $planContent = $planContent.Replace(
            '{ "iteration": N, "batch": [ { "req_id", "description", "generation_instructions", "target_files", "pattern" } ] }',
            '{ "iteration": N, "batch": [ { "req_id", "description", "generation_instructions", "target_files", "pattern", "complexity" } ] }' + "`n`n   **complexity** (REQUIRED): `"low`" | `"medium`" | `"high`"`n   - low: CRUD, utility, SQL view, config, seed data`n   - medium: feature with UI+API, auth, form validation`n   - high: compliance (HIPAA/PCI/GDPR), cross-cutting, complex business logic, security"
        )
        $planContent | Set-Content $planPath -Encoding UTF8
        Write-Host "  [OK] plan.md: added complexity field guidance" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] plan.md already has complexity field" -ForegroundColor DarkGray
    }
} else {
    Write-Host "  [WARN] plan.md not found" -ForegroundColor Yellow
}

# ── 7. Update synthesize.md: add DeepSeek to expertise + 3-reviewer voting ───

$synthesizePath = "$GsdGlobalDir\prompts\council\synthesize.md"
if (Test-Path $synthesizePath) {
    $synthContent = Get-Content $synthesizePath -Raw
    if ($synthContent -notmatch "DeepSeek.*patterns") {
        $synthContent = $synthContent.Replace(
            "   - Gemini: Requirements & spec alignment expert",
            "   - Gemini: Requirements & spec alignment expert`n   - DeepSeek: Code patterns, maintainability & security expert (when present)"
        )
        $synthContent = $synthContent.Replace(
            "- If both agents vote `"concern`" with similar issues: verdict is BLOCKED",
            "- If majority of agents vote `"concern`" with overlapping issues: verdict is BLOCKED`n- With 3 reviewers: 2-1 majority determines outcome (1 block + 2 approve = APPROVED with concerns noted)"
        )
        $synthContent = $synthContent.Replace(
            '"gemini": "approve|concern|block"',
            '"gemini": "approve|concern|block",' + "`n    `"deepseek`": `"approve|concern|block|absent`""
        )
        $synthContent | Set-Content $synthesizePath -Encoding UTF8
        Write-Host "  [OK] synthesize.md updated for 3-reviewer council" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] synthesize.md already has DeepSeek" -ForegroundColor DarkGray
    }
} else {
    Write-Host "  [WARN] synthesize.md not found" -ForegroundColor Yellow
}

# ── 8. Add Invoke-ParallelResearch + Get-AgentForComplexity to resilience.ps1 ─

$resilienceFile = "$GsdGlobalDir\lib\modules\resilience.ps1"
if (Test-Path $resilienceFile) {
    $resContent = Get-Content $resilienceFile -Raw

    if ($resContent -notlike "*function Invoke-ParallelResearch*") {
        $newFunctions = @'

# ===========================================
# 7-MODEL OPTIMIZATION: PARALLEL RESEARCH
# ===========================================

function Invoke-ParallelResearch {
    param(
        [string]$GsdDir, [string]$GlobalDir, [int]$Iteration,
        [decimal]$Health, [string]$RepoRoot, [string]$InterfaceContext = ""
    )
    $result = @{ Success = $false; Error = "" }
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (-not (Test-Path $configPath)) { $result.Error = "config not found"; return $result }
    $config = Get-Content $configPath -Raw | ConvertFrom-Json
    if (-not $config.parallel_research -or -not $config.parallel_research.enabled) {
        $result.Error = "parallel_research not enabled"; return $result
    }
    $researchCfg = $config.parallel_research
    $timeoutSec  = [int]$researchCfg.timeout_minutes * 60
    $figmaPath   = Join-Path $RepoRoot "design\figma"
    if (-not (Test-Path $figmaPath)) { $figmaPath = Join-Path $RepoRoot "design" }
    $jobs = @()
    foreach ($agentCfg in $researchCfg.agents) {
        $agentName  = $agentCfg.agent
        $promptDir  = if ($agentCfg.prompt_dir) { $agentCfg.prompt_dir } else { "shared" }
        $promptFile = Join-Path $GlobalDir "prompts\$promptDir\$($agentCfg.prompt)"
        if (-not (Test-Path $promptFile)) {
            Write-Host "  [PAR-RESEARCH] Prompt not found for $agentName -- skipping" -ForegroundColor Yellow
            continue
        }
        $phases = if ($agentCfg.phases) { ($agentCfg.phases -join "+") } else { "?" }
        Write-Host "  [PAR-RESEARCH] Dispatching $agentName -> Phase $phases" -ForegroundColor DarkCyan
        $job = Start-Job -Name "gsd-research-$agentName" -ScriptBlock {
            param($Agent, $PromptFile, $GsdDir, $GlobalDir, $Iteration, $Health, $RepoRoot, $FigmaPath, $InterfaceContext)
            . "$GlobalDir\lib\modules\resilience.ps1"
            $promptText = Get-Content $PromptFile -Raw
            $promptText = $promptText.Replace("{{ITERATION}}", "$Iteration")
            $promptText = $promptText.Replace("{{HEALTH}}", "$Health")
            $promptText = $promptText.Replace("{{GSD_DIR}}", $GsdDir)
            $promptText = $promptText.Replace("{{REPO_ROOT}}", $RepoRoot)
            $promptText = $promptText.Replace("{{FIGMA_PATH}}", $FigmaPath)
            $promptText = $promptText.Replace("{{INTERFACE_CONTEXT}}", $InterfaceContext)
            $logFile = "$GsdDir\logs\iter${Iteration}-2-research-${Agent}.log"
            $subResult = Invoke-WithRetry -Agent $Agent -Prompt $promptText `
                -Phase "research" -LogFile $logFile -CurrentBatchSize 1 -GsdDir $GsdDir -MaxAttempts 2
            return @{ Agent = $Agent; Success = $subResult.Success; Error = $subResult.Error }
        } -ArgumentList $agentName, $promptFile, $GsdDir, $GlobalDir, $Iteration, $Health, $RepoRoot, $figmaPath, $InterfaceContext
        $jobs += $job
    }
    if ($jobs.Count -eq 0) { $result.Error = "No research agents dispatched"; return $result }
    $jobs | Wait-Job -Timeout $timeoutSec | Out-Null
    $succeeded = 0; $failed = 0
    foreach ($job in $jobs) {
        $jr = $null
        if ($job.State -eq "Completed") { $jr = Receive-Job $job -ErrorAction SilentlyContinue }
        if ($jr -and $jr.Success) {
            $succeeded++
            Write-Host "  [PAR-RESEARCH] $($jr.Agent): OK" -ForegroundColor Green
        } else {
            $failed++
            $errMsg = if ($jr) { $jr.Error } else { "timed out" }
            Write-Host "  [PAR-RESEARCH] $($job.Name): FAIL ($errMsg)" -ForegroundColor Yellow
        }
        Remove-Job $job -Force -ErrorAction SilentlyContinue
    }
    if ($succeeded -gt 0) {
        $mergedPath = Join-Path $GsdDir "research\research-findings.md"
        $merged     = "# Research Findings -- Parallel (Iteration $Iteration)`n`n"
        $merged    += "> Gemini: Phase A+B | DeepSeek: Phase C+D | Kimi: Phase E+Figma`n`n"
        foreach ($suffix in @("ab", "cd", "e-figma")) {
            $subFile = Join-Path $GsdDir "research\research-findings-$suffix.md"
            if (Test-Path $subFile) { $merged += (Get-Content $subFile -Raw).Trim() + "`n`n---`n`n" }
        }
        $merged | Set-Content $mergedPath -Encoding UTF8
        Write-Host "  [PAR-RESEARCH] Merged research-findings.md ($succeeded/$($succeeded+$failed) agents OK)" -ForegroundColor Green
        $result.Success = $true
    } else {
        $result.Error = "All parallel research agents failed"
    }
    return $result
}

# ===========================================
# 7-MODEL OPTIMIZATION: COMPLEXITY ROUTING
# ===========================================

function Get-AgentForComplexity {
    param(
        [string]$Complexity,
        [string]$GlobalDir,
        [string[]]$AvailableAgents,
        [int]$Index = 0
    )
    $fallback   = $AvailableAgents[$Index % $AvailableAgents.Count]
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (-not (Test-Path $configPath)) { return $fallback }
    try {
        $config = Get-Content $configPath -Raw | ConvertFrom-Json
        if (-not $config.complexity_routing -or -not $config.complexity_routing.enabled) { return $fallback }
        $preferred = switch ($Complexity) {
            "low"    { @($config.complexity_routing.low.preferred_agents) }
            "medium" { @($config.complexity_routing.medium.preferred_agents) }
            "high"   { @($config.complexity_routing.high.preferred_agents) }
            default  { @() }
        }
        foreach ($p in $preferred) {
            if ($AvailableAgents -contains $p) {
                if ($p -ne $fallback) {
                    Write-Host "  [COMPLEXITY] $Complexity -> $p (preferred over $fallback)" -ForegroundColor DarkCyan
                }
                return $p
            }
        }
    } catch {}
    return $fallback
}
'@
        Add-Content -Path $resilienceFile -Value $newFunctions -Encoding UTF8
        Write-Host "  [OK] Added Invoke-ParallelResearch + Get-AgentForComplexity to resilience.ps1" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] Invoke-ParallelResearch already in resilience.ps1" -ForegroundColor DarkGray
    }

    # Patch complexity routing in Invoke-ParallelExecute
    $resContent = Get-Content $resilienceFile -Raw
    if ($resContent -like "*Select agent: round-robin across pool*") {
        $resContent = $resContent.Replace(
            "        # Select agent: round-robin across pool`n        if (`$strategy -eq `"round-robin`") {`n            `$agent = `$agentPool[`$idx % `$agentPool.Count]`n        } else {`n            `$agent = `$agentPool[0]`n        }",
            "        # Select agent: complexity-based routing with round-robin fallback`n        `$itemComplexity = if (`$item.complexity) { `$item.complexity } else { `"medium`" }`n        if ((Get-Command Get-AgentForComplexity -ErrorAction SilentlyContinue) -and `$strategy -ne `"all-same`") {`n            `$agent = Get-AgentForComplexity -Complexity `$itemComplexity -GlobalDir `$GlobalDir -AvailableAgents `$agentPool -Index `$idx`n        } elseif (`$strategy -eq `"round-robin`") {`n            `$agent = `$agentPool[`$idx % `$agentPool.Count]`n        } else {`n            `$agent = `$agentPool[0]`n        }"
        )
        $resContent | Set-Content $resilienceFile -Encoding UTF8
        Write-Host "  [OK] Patched Invoke-ParallelExecute: complexity routing" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] complexity routing already patched in Invoke-ParallelExecute" -ForegroundColor DarkGray
    }

    # Patch adaptive cooldown in Invoke-ParallelExecute
    $resContent = Get-Content $resilienceFile -Raw
    if ($resContent -like "*10s cooldown*") {
        $resContent = $resContent.Replace(
            "        # Throttle between waves (avoid quota spike)`n        if (`$batchEnd -lt (`$subtasks.Count - 1)) {`n            Write-Host `"  [PARALLEL] Wave complete. 10s cooldown...`" -ForegroundColor DarkGray`n            Start-Sleep -Seconds 10`n        }",
            "        # Throttle between waves (adaptive: 3s clean / 30s quota pressure)`n        if (`$batchEnd -lt (`$subtasks.Count - 1)) {`n            `$cooldownSec = 3`n            `$cooldownsPath = Join-Path `$GsdDir `"supervisor\agent-cooldowns.json`"`n            if (Test-Path `$cooldownsPath) {`n                try {`n                    `$cooldowns = Get-Content `$cooldownsPath -Raw | ConvertFrom-Json`n                    `$cutoff = (Get-Date).AddMinutes(-5)`n                    foreach (`$prop in `$cooldowns.PSObject.Properties) {`n                        if ([string]`$prop.Value -ne `"`" -and ([DateTime]::Parse(`$prop.Value)) -gt `$cutoff) { `$cooldownSec = 30; break }`n                    }`n                } catch { `$cooldownSec = 10 }`n            }`n            Write-Host `"  [PARALLEL] Wave complete. `${cooldownSec}s adaptive cooldown...`" -ForegroundColor DarkGray`n            Start-Sleep -Seconds `$cooldownSec`n        }"
        )
        $resContent | Set-Content $resilienceFile -Encoding UTF8
        Write-Host "  [OK] Patched Invoke-ParallelExecute: adaptive cooldown" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] adaptive cooldown already patched" -ForegroundColor DarkGray
    }
} else {
    Write-Host "  [WARN] resilience.ps1 not found" -ForegroundColor Yellow
}

# ── 9. Patch convergence-loop.ps1: parallel research + Figma-First + agent intel ─

$convergenceFile = "$GsdGlobalDir\scripts\convergence-loop.ps1"
if (Test-Path $convergenceFile) {
    $loopContent = Get-Content $convergenceFile -Raw

    # Parallel research section
    if ($loopContent -notlike "*Invoke-ParallelResearch*") {
        $oldResearch = '    # 2. RESEARCH (Gemini plan mode, read-only - saves Claude/Codex quota)'
        $newResearch = '    # 2. RESEARCH (Parallel: Gemini->PhaseA+B, DeepSeek->PhaseC+D, Kimi->PhaseE+Figma)'
        if ($loopContent -like "*$oldResearch*") {
            # Find and replace the entire research block
            $startIdx = $loopContent.IndexOf($oldResearch)
            $endMarker = '    # ── POST-RESEARCH COUNCIL'
            $endIdx = $loopContent.IndexOf($endMarker)
            if ($startIdx -ge 0 -and $endIdx -gt $startIdx) {
                $before = $loopContent.Substring(0, $startIdx)
                $after  = $loopContent.Substring($endIdx)
                $newBlock = "    # 2. RESEARCH (Parallel: Gemini->PhaseA+B, DeepSeek->PhaseC+D, Kimi->PhaseE+Figma)`n    if (-not `$SkipResearch) {`n        Send-HeartbeatIfDue -Phase `"research`" -Iteration `$Iteration -Health `$Health -RepoName `$repoName`n        if (-not (Test-Path `"`$GsdDir\research`")) { New-Item -ItemType Directory -Path `"`$GsdDir\research`" -Force | Out-Null }`n        `$parallelResearchOk = `$false`n        if ((Get-Command Invoke-ParallelResearch -ErrorAction SilentlyContinue) -and -not `$DryRun) {`n            Write-Host `"  [PAR-RESEARCH] Gemini+DeepSeek+Kimi -> parallel research`" -ForegroundColor Magenta`n            if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {`n                Update-EngineStatus -GsdDir `$GsdDir -State `"running`" -Phase `"research`" -Agent `"parallel(gemini+deepseek+kimi)`" -Iteration `$Iteration -HealthScore `$Health`n            }`n            Save-Checkpoint -GsdDir `$GsdDir -Pipeline `"converge`" -Iteration `$Iteration -Phase `"research`" -Health `$Health -BatchSize `$CurrentBatchSize`n            `$prResult = Invoke-ParallelResearch -GsdDir `$GsdDir -GlobalDir `$GlobalDir -Iteration `$Iteration -Health `$Health -RepoRoot `$RepoRoot -InterfaceContext `$InterfaceContext`n            if (`$prResult.Success) { `$parallelResearchOk = `$true } else { Write-Host `"  [PAR-RESEARCH] Failed (`$(`$prResult.Error)) -- falling back`" -ForegroundColor Yellow }`n        }`n        if (-not `$parallelResearchOk -and -not `$DryRun) {`n            `$useGemini = `$null -ne (Get-Command gemini -ErrorAction SilentlyContinue)`n            if (`$useGemini) {`n                Write-Host `"  GEMINI -> research (sequential fallback)`" -ForegroundColor Magenta`n                if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) { Update-EngineStatus -GsdDir `$GsdDir -State `"running`" -Phase `"research`" -Agent `"gemini`" -Iteration `$Iteration -HealthScore `$Health }`n                `$prompt = Local-ResolvePrompt `"`$GlobalDir\prompts\gemini\research.md`" `$Iteration `$Health`n                Invoke-WithRetry -Agent `"gemini`" -Prompt `$prompt -Phase `"research`" -LogFile `"`$GsdDir\logs\iter`${Iteration}-2.log`" -CurrentBatchSize `$CurrentBatchSize -GsdDir `$GsdDir -GeminiMode `"--approval-mode plan`" | Out-Null`n            } else {`n                Write-Host `"  CODEX -> research (sequential fallback)`" -ForegroundColor Magenta`n                if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) { Update-EngineStatus -GsdDir `$GsdDir -State `"running`" -Phase `"research`" -Agent `"codex`" -Iteration `$Iteration -HealthScore `$Health }`n                `$prompt = Local-ResolvePrompt `"`$GlobalDir\prompts\codex\research.md`" `$Iteration `$Health`n                Invoke-WithRetry -Agent `"codex`" -Prompt `$prompt -Phase `"research`" -LogFile `"`$GsdDir\logs\iter`${Iteration}-2.log`" -CurrentBatchSize `$CurrentBatchSize -GsdDir `$GsdDir | Out-Null`n            }`n        }`n    }`n"
                ($before + $newBlock + $after) | Set-Content $convergenceFile -Encoding UTF8
                Write-Host "  [OK] convergence-loop.ps1: parallel research section" -ForegroundColor Green
            } else {
                Write-Host "  [WARN] Could not locate research block boundaries in convergence-loop.ps1" -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host "  [SKIP] convergence-loop.ps1 already has parallel research" -ForegroundColor DarkGray
    }

    # Figma-First + Get-BestAgentForPhase wiring
    $loopContent = Get-Content $convergenceFile -Raw
    if ($loopContent -notlike "*FIGMA-FIRST MODE*") {
        $loopContent = $loopContent.Replace(
            '        $executeAgent = "codex"',
            '        $executeAgent = if (Get-Command Get-BestAgentForPhase -ErrorAction SilentlyContinue) { Get-BestAgentForPhase -GsdDir $GsdDir -GlobalDir $GlobalDir -Phase "execute" -DefaultAgent "codex" } else { "codex" }'
        )
        $loopContent | Set-Content $convergenceFile -Encoding UTF8
        Write-Host "  [OK] convergence-loop.ps1: wired Get-BestAgentForPhase for monolithic execute" -ForegroundColor Green

        $loopContent = Get-Content $convergenceFile -Raw
        $loopContent = $loopContent.Replace(
            '        $prompt = Local-ResolvePrompt "$GlobalDir\prompts\codex\execute.md" $Iteration $Health',
            '        $figmaFirstHeader = ""`n        $queueDataPath = Join-Path $GsdDir "generation-queue\queue-current.json"`n        if (Test-Path $queueDataPath) {`n            try {`n                $queueData = Get-Content $queueDataPath -Raw | ConvertFrom-Json`n                $uiItems = @($queueData.batch | Where-Object { ($_.target_files -join " ") -match "\.(tsx|jsx|css|scss)" -or ($_.description -match "component|UI|frontend|screen|page|modal|form|layout|nav") })`n                if ($uiItems.Count -gt 0) {`n                    $figmaFirstHeader = "## FIGMA-FIRST MODE ($($uiItems.Count) UI requirements detected)`n`n**READ FIGMA ANALYSIS FILES BEFORE WRITING ANY CODE.**`nEvery UI component MUST match Figma: layout, spacing, typography, colors, all interactive states.`n`n---`n`n"`n                    Write-Host "  [FIGMA-FIRST] $($uiItems.Count) UI item(s) -- Figma-First mode active" -ForegroundColor Cyan`n                }`n            } catch {}`n        }`n        $prompt = Local-ResolvePrompt "$GlobalDir\prompts\codex\execute.md" $Iteration $Health`n        if ($figmaFirstHeader) { $prompt = $figmaFirstHeader + $prompt }'
        )
        $loopContent | Set-Content $convergenceFile -Encoding UTF8
        Write-Host "  [OK] convergence-loop.ps1: Figma-First mode injection" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] convergence-loop.ps1 already has Figma-First mode" -ForegroundColor DarkGray
    }
} else {
    Write-Host "  [WARN] convergence-loop.ps1 not found" -ForegroundColor Yellow
}

# ── Done ──────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Green
Write-Host "  GSD 7-Model Optimization: ALL 12 changes applied" -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Changes applied:" -ForegroundColor White
Write-Host "  1.  max_concurrent: 7 (all 7 agents execute in parallel)" -ForegroundColor DarkGray
Write-Host "  2.  max_batch: 14 (7-agent calibrated)" -ForegroundColor DarkGray
Write-Host "  3.  Parallel research: Gemini+DeepSeek+Kimi (3 spec phases)" -ForegroundColor DarkGray
Write-Host "  4.  Get-BestAgentForPhase wired into monolithic execute" -ForegroundColor DarkGray
Write-Host "  5.  Plan reads pattern-analysis.md + tech-decisions.md" -ForegroundColor DarkGray
Write-Host "  6.  Acceptance test hard-blocking on file_exists+pattern_match+build_check" -ForegroundColor DarkGray
Write-Host "  7.  5-partition review: DeepSeek(Phase D) + Kimi(Phase E+Figma)" -ForegroundColor DarkGray
Write-Host "  8.  DeepSeek as 3rd council reviewer" -ForegroundColor DarkGray
Write-Host "  9.  Research auto-skip disabled (parallel research always runs)" -ForegroundColor DarkGray
Write-Host "  10. Figma-First mode for UI batches in execute" -ForegroundColor DarkGray
Write-Host "  11. Adaptive wave cooldown: 3s clean / 30s quota-pressure" -ForegroundColor DarkGray
Write-Host "  12. Complexity routing: low->DeepSeek, medium->Kimi/Codex, high->Claude/Codex" -ForegroundColor DarkGray
Write-Host ""
