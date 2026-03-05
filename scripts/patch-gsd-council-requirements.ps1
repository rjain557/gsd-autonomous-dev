<#
.SYNOPSIS
    GSD Council Requirements Verification - Multi-Agent Requirements Extraction
    Run AFTER patch-gsd-partitioned-code-review.ps1.

.DESCRIPTION
    Adds council-based requirements extraction where ALL 3 agents (Claude, Codex, Gemini)
    independently extract requirements from specs, Figma, and code, then Claude synthesizes
    a merged, deduplicated, confidence-scored requirements-matrix.json.

    Each agent has a different extraction focus:
    - Claude: Architecture, compliance (HIPAA/SOC2/PCI/GDPR), cross-cutting concerns
    - Codex:  Implementation completeness, code patterns, implied requirements from code
    - Gemini: Spec/Figma alignment, UI requirements, missing UX states

    Confidence scoring:
    - Found by 3 agents = "high"   (all agree it exists)
    - Found by 2 agents = "medium" (majority agree)
    - Found by 1 agent  = "low"    (flagged for human review)

    Can run standalone on any repo via: gsd-verify-requirements
    Or integrate into convergence pipeline as Phase 0 alternative.

.INSTALL_ORDER
    1-34. (existing scripts)
    35. patch-gsd-council-requirements.ps1  <- this file

.NOTES
    Schema changes are additive (backward compatible):
    - New fields per requirement: confidence, found_by
    - New meta fields: extraction_method, agents_participated, timestamp
#>

param([string]$UserHome = $env:USERPROFILE)
$ErrorActionPreference = "Stop"

$GsdGlobalDir = Join-Path $UserHome ".gsd-global"

if (-not (Test-Path "$GsdGlobalDir\lib\modules\resilience.ps1")) {
    Write-Host "[XX] Resilience library not found. Run install-gsd-global.ps1 first." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  GSD Council Requirements Verification" -ForegroundColor Cyan
Write-Host "  3-Agent Independent Extraction + Synthesis" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

# ========================================================
# 1. Add council_requirements config
# ========================================================

$configPath = Join-Path $GsdGlobalDir "config\global-config.json"
if (Test-Path $configPath) {
    $config = Get-Content $configPath -Raw | ConvertFrom-Json

    if (-not $config.council_requirements) {
        $config | Add-Member -NotePropertyName "council_requirements" -NotePropertyValue ([PSCustomObject]@{
            enabled                = $true
            agents                 = @("claude", "codex", "gemini")
            min_agents_for_merge   = 2
            timeout_seconds        = 600
            cooldown_between_agents = 5
            fallback_to_single     = $true
        })
        $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath -Encoding UTF8
        Write-Host "  [OK] Added council_requirements config" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] council_requirements config already exists" -ForegroundColor DarkGray
    }
}

# ========================================================
# 2. Create council prompt templates
# ========================================================

$promptDir = Join-Path $GsdGlobalDir "prompts\council"
if (-not (Test-Path $promptDir)) {
    New-Item -Path $promptDir -ItemType Directory -Force | Out-Null
}

# Template: Claude extraction (architecture & compliance focus)
$claudeExtract = @'
# Council Requirements Extraction -- Architecture & Compliance (Claude)

You are 1 of 3 independent agents extracting requirements. Your focus: ARCHITECTURE and COMPLIANCE.

## Context
- Project: {{REPO_ROOT}}
- GSD dir: {{GSD_DIR}}
- Specs: docs\ (SDLC Phase A-E)
- Designs: design\ (Figma analysis if present)

{{INTERFACE_CONTEXT}}

## Read These Files
1. Every file in docs\ (SDLC specification documents)
2. design\ -- all Figma analysis/design files
3. Existing codebase structure (scan src\ or equivalent)
4. Any existing {{GSD_DIR}}\specs\ files
5. {{GSD_DIR}}\file-map-tree.md (repo structure)

## Your Focus Areas
1. **Architecture**: Layer isolation, DI patterns, API contracts, data flow (UI->API->SP->DB)
2. **Compliance**: HIPAA (PHI handling, audit logs), SOC 2 (access controls), PCI (payment data), GDPR (consent)
3. **Cross-cutting**: Logging, caching, error handling, authentication, authorization
4. **Database**: Table schemas, stored procedures, migrations, seed data
5. **Integration**: End-to-end chains, external service calls, message queues

## Extract ALL Requirements
For EVERY discrete requirement found in specs, Figma, compliance rules, or implied by code:

## Output (max 5000 tokens)
Write ONLY a JSON file to {{GSD_DIR}}\health\council-extract-claude.json:

```json
{
  "agent": "claude",
  "focus": "architecture_compliance",
  "requirements": [
    {
      "id": "CL-001",
      "description": "One sentence requirement description",
      "source": "spec|figma|compliance|code",
      "spec_doc": "docs/Phase-X-xxx.md",
      "sdlc_phase": "Phase-A|Phase-B|Phase-C|Phase-D|Phase-E",
      "pattern": "backend|frontend|database|integration|security",
      "priority": "high|medium|low",
      "status": "satisfied|partial|not_started",
      "satisfied_by": "path/to/file.cs (if satisfied or partial)",
      "notes": "Brief evidence or file reference"
    }
  ],
  "total_found": 0
}
```

Rules:
- Be EXHAUSTIVE -- every missed requirement is a gap that won't get built
- One sentence per description. No prose paragraphs.
- Include file paths as evidence for status assessments
- Scan actual code to determine status (don't guess from filenames)
- Prefix IDs with CL- (e.g., CL-001, CL-002)
'@

Set-Content -Path (Join-Path $promptDir "requirements-extract-claude.md") -Value $claudeExtract -Encoding UTF8
Write-Host "  [OK] Created requirements-extract-claude.md" -ForegroundColor Green

# Template: Codex extraction (implementation & code focus)
$codexExtract = @'
# Council Requirements Extraction -- Implementation & Code (Codex)

You are 1 of 3 independent agents extracting requirements. Your focus: IMPLEMENTATION and CODE.

## Context
- Project: {{REPO_ROOT}}
- GSD dir: {{GSD_DIR}}
- Specs: docs\ (SDLC Phase A-E)
- Designs: design\ (Figma analysis if present)

{{INTERFACE_CONTEXT}}

## Read These Files
1. Source code files in src\ (or equivalent project root)
2. Package/project files: package.json, *.csproj, *.sln, appsettings.json
3. Every file in docs\ (specification documents)
4. {{GSD_DIR}}\file-map-tree.md (repo structure)
5. Database scripts: db\, src\database\, *.sql files

## Your Focus Areas
1. **Code completeness**: API endpoints defined but not wired, DB objects referenced but not created
2. **Pattern compliance**: SP-Only (no inline SQL), Dapper (not EF), correct DI lifetimes
3. **Missing implementations**: Controllers without services, services without repositories
4. **Runtime requirements**: Error handling, input validation, response codes, pagination
5. **Implied requirements**: Things the code needs that specs don't mention (config, DI registration, middleware)

## Extract ALL Requirements
For EVERY discrete requirement found in code, specs, or implied by implementation gaps:

## Output (max 5000 tokens)
Write ONLY a JSON file to {{GSD_DIR}}\health\council-extract-codex.json:

```json
{
  "agent": "codex",
  "focus": "implementation_code",
  "requirements": [
    {
      "id": "CX-001",
      "description": "One sentence requirement description",
      "source": "spec|figma|compliance|code",
      "spec_doc": "docs/Phase-X-xxx.md",
      "sdlc_phase": "Phase-A|Phase-B|Phase-C|Phase-D|Phase-E",
      "pattern": "backend|frontend|database|integration|security",
      "priority": "high|medium|low",
      "status": "satisfied|partial|not_started",
      "satisfied_by": "path/to/file.cs (if satisfied or partial)",
      "notes": "Brief evidence or file reference"
    }
  ],
  "total_found": 0
}
```

Rules:
- Be EXHAUSTIVE -- every missed requirement is a gap that won't get built
- One sentence per description. No prose paragraphs.
- READ actual source files to determine status accurately
- Flag implied requirements (things code needs but specs omit)
- Prefix IDs with CX- (e.g., CX-001, CX-002)
'@

Set-Content -Path (Join-Path $promptDir "requirements-extract-codex.md") -Value $codexExtract -Encoding UTF8
Write-Host "  [OK] Created requirements-extract-codex.md" -ForegroundColor Green

# Template: Gemini extraction (spec & Figma alignment focus)
$geminiExtract = @'
# Council Requirements Extraction -- Spec & Figma Alignment (Gemini)

You are 1 of 3 independent agents extracting requirements. Your focus: SPEC and FIGMA alignment.

## Context
- Project: {{REPO_ROOT}}
- GSD dir: {{GSD_DIR}}
- Specs: docs\ (SDLC Phase A-E)
- Designs: design\ (Figma analysis if present)

{{INTERFACE_CONTEXT}}

## Read These Files
1. Every file in docs\ (SDLC specification documents) -- read COMPLETELY
2. design\ -- all Figma analysis, storyboard, and design files -- read COMPLETELY
3. {{GSD_DIR}}\specs\ -- any existing spec mappings
4. {{GSD_DIR}}\file-map-tree.md (repo structure)
5. src\ -- scan structure to check what exists

## Your Focus Areas
1. **Spec coverage**: Every feature, endpoint, and business rule in specification documents
2. **Figma coverage**: Every screen, component, form field, navigation flow, interaction state
3. **Missing UX states**: Loading, error, empty, disabled, hover, focus, responsive breakpoints
4. **Form requirements**: Validation rules, error messages, field types, required/optional
5. **User flows**: Complete end-to-end user journeys from specs (login, CRUD, search, export)

## Extract ALL Requirements
For EVERY discrete requirement found in specs, Figma, or implied by UX completeness:

## Output (max 5000 tokens)
Write ONLY a JSON file to {{GSD_DIR}}\health\council-extract-gemini.json:

```json
{
  "agent": "gemini",
  "focus": "spec_figma_alignment",
  "requirements": [
    {
      "id": "GM-001",
      "description": "One sentence requirement description",
      "source": "spec|figma|compliance|code",
      "spec_doc": "docs/Phase-X-xxx.md",
      "sdlc_phase": "Phase-A|Phase-B|Phase-C|Phase-D|Phase-E",
      "pattern": "backend|frontend|database|integration|security",
      "priority": "high|medium|low",
      "status": "satisfied|partial|not_started",
      "satisfied_by": "path/to/file.tsx (if satisfied or partial)",
      "notes": "Brief evidence or file reference"
    }
  ],
  "total_found": 0
}
```

Rules:
- Be EXHAUSTIVE -- every missed requirement is a gap that won't get built
- One sentence per description. No prose paragraphs.
- Read EVERY spec document completely (don't skim)
- Include UX states that are commonly missed (loading, error, empty, 404)
- Prefix IDs with GM- (e.g., GM-001, GM-002)
'@

Set-Content -Path (Join-Path $promptDir "requirements-extract-gemini.md") -Value $geminiExtract -Encoding UTF8
Write-Host "  [OK] Created requirements-extract-gemini.md" -ForegroundColor Green

# Template: Synthesis (merge/dedup/confidence)
$synthesize = @'
# Council Requirements Synthesis -- Merge & Deduplicate

You are the JUDGE synthesizing 2-3 independent requirement extractions into one
unified, deduplicated, confidence-scored requirements-matrix.json.

## Agent Extractions
Read the extraction files below. Each agent extracted requirements independently with a different focus.

{{AGENT_OUTPUTS}}

## Your Task
1. **DEDUPLICATE**: Requirements describing the same thing (even with different wording)
   get merged into ONE entry. Use the best description from any agent.
2. **SCORE CONFIDENCE**:
   - Found by 3 agents = "high" (all agree it exists)
   - Found by 2 agents = "medium" (majority agree)
   - Found by 1 agent = "low" (flagged for review)
3. **RESOLVE CONFLICTS**:
   - Status disagreement: use MOST CONSERVATIVE (not_started > partial > satisfied)
   - Priority disagreement: use HIGHEST priority
   - Pattern disagreement: use most specific one
4. **PRESERVE provenance**: Track which agents found each requirement

## Deduplication Rules
Two requirements are the SAME if:
- They reference the same API endpoint, database table, UI component, or business rule
- They describe the same functionality even with different wording
- One is a subset of the other (keep the more detailed version)

Two requirements are DIFFERENT if:
- They address different layers (e.g., "API for login" vs "UI for login form")
- They have different acceptance criteria
- One is about implementation, the other about testing/compliance

## Output (max 5000 tokens)
Write the FINAL requirements-matrix.json to {{GSD_DIR}}\health\requirements-matrix.json:

```json
{
  "meta": {
    "total_requirements": 0,
    "satisfied": 0,
    "partial": 0,
    "not_started": 0,
    "health_score": 0,
    "iteration": 0,
    "extraction_method": "council",
    "agents_participated": [],
    "timestamp": "ISO-8601"
  },
  "requirements": [
    {
      "id": "REQ-001",
      "description": "Best description from any agent",
      "source": "spec|figma|compliance|code",
      "spec_doc": "docs/X.md",
      "sdlc_phase": "Phase-X",
      "pattern": "backend|frontend|database|integration|security",
      "priority": "high|medium|low",
      "status": "satisfied|partial|not_started",
      "satisfied_by": "file path if satisfied",
      "notes": "Evidence notes",
      "confidence": "high|medium|low",
      "found_by": ["claude", "codex", "gemini"]
    }
  ]
}
```

Also write a summary to {{GSD_DIR}}\health\council-requirements-report.md with:
- Total requirements, confidence breakdown, agent agreement rate
- Table of low-confidence requirements for human review
- Statistics per agent (unique finds, overlap percentage)

Also write {{GSD_DIR}}\health\health-current.json:
```json
{ "health_score": X, "total_requirements": N, "satisfied": N, "partial": N, "not_started": N, "iteration": 0 }
```

Also write initial {{GSD_DIR}}\health\drift-report.md listing all not_started and partial requirements.

Rules:
- Assign sequential IDs: REQ-001, REQ-002, ...
- Calculate health_score = (satisfied / total) * 100
- Sort requirements by: priority desc, sdlc_phase, pattern
'@

Set-Content -Path (Join-Path $promptDir "requirements-synthesize.md") -Value $synthesize -Encoding UTF8
Write-Host "  [OK] Created requirements-synthesize.md" -ForegroundColor Green

# Template: Partial synthesis (2-agent fallback)
$synthesizePartial = @'
# Council Requirements Synthesis -- Partial (2 of 3 agents)

You are the JUDGE synthesizing requirement extractions. Only {{AGENT_COUNT}} of 3 agents succeeded.
Maximum confidence for any requirement is "medium" (since not all agents participated).

## Agent Extractions
{{AGENT_OUTPUTS}}

## Missing Agent
{{MISSING_AGENT}} did not complete extraction. Its focus area may have gaps.

## Your Task
Same as full synthesis but:
- Max confidence = "medium" (never "high" with < 3 agents)
- Flag the missing agent's focus area as potentially incomplete
- Note in the report which requirements may be missing due to the failed agent

## Output
Same format as full synthesis. Write to:
- {{GSD_DIR}}\health\requirements-matrix.json
- {{GSD_DIR}}\health\council-requirements-report.md
- {{GSD_DIR}}\health\health-current.json
- {{GSD_DIR}}\health\drift-report.md
'@

Set-Content -Path (Join-Path $promptDir "requirements-synthesize-partial.md") -Value $synthesizePartial -Encoding UTF8
Write-Host "  [OK] Created requirements-synthesize-partial.md" -ForegroundColor Green

# ========================================================
# 3. Append functions to resilience library
# ========================================================

Write-Host ""
Write-Host "[SCALES] Adding Council Requirements module to resilience library..." -ForegroundColor Yellow

$councilReqCode = @'

# ===============================================================
# GSD COUNCIL REQUIREMENTS MODULE - appended to resilience.ps1
# ===============================================================

function Invoke-CouncilRequirements {
    <#
    .SYNOPSIS
        Multi-agent requirements extraction: 3 agents independently extract requirements
        from specs, Figma, and code, then Claude synthesizes a merged matrix.
    .RETURNS
        @{ Success = bool; MatrixPath = string; AgentsSucceeded = int; Error = string }
    #>
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [switch]$DryRun,
        [bool]$UseJobs = $true,
        [string]$SkipAgent = ""
    )

    $result = @{
        Success         = $false
        MatrixPath      = Join-Path $GsdDir "health\requirements-matrix.json"
        AgentsSucceeded = 0
        Error           = ""
    }

    $globalDir = Join-Path $env:USERPROFILE ".gsd-global"
    $promptDir = Join-Path $globalDir "prompts\council"
    $healthDir = Join-Path $GsdDir "health"
    $logDir    = Join-Path $GsdDir "logs"

    foreach ($d in @($healthDir, $logDir)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }

    # Load config
    $crConfig = $null
    $configPath = Join-Path $globalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try { $crConfig = (Get-Content $configPath -Raw | ConvertFrom-Json).council_requirements } catch {}
    }
    $timeout  = if ($crConfig -and $crConfig.timeout_seconds) { [int]$crConfig.timeout_seconds } else { 600 }
    $cooldown = if ($crConfig -and $crConfig.cooldown_between_agents) { [int]$crConfig.cooldown_between_agents } else { 5 }
    $minAgents = if ($crConfig -and $crConfig.min_agents_for_merge) { [int]$crConfig.min_agents_for_merge } else { 2 }

    # Build interface context
    $InterfaceContext = ""
    if (Get-Command Initialize-ProjectInterfaces -ErrorAction SilentlyContinue) {
        try {
            $ifaceResult = Initialize-ProjectInterfaces -RepoRoot $RepoRoot -GsdDir $GsdDir
            $InterfaceContext = $ifaceResult.Context
        } catch {}
    }

    # Agent definitions
    $agents = @(
        @{ Name = "claude";  Template = "requirements-extract-claude.md";  AllowedTools = "Read,Write,Bash"; GeminiMode = $null }
        @{ Name = "codex";   Template = "requirements-extract-codex.md";   AllowedTools = $null;             GeminiMode = $null }
        @{ Name = "gemini";  Template = "requirements-extract-gemini.md";  AllowedTools = $null;             GeminiMode = "--approval-mode plan" }
    )

    # Filter out skipped agent
    if ($SkipAgent) {
        $agents = @($agents | Where-Object { $_.Name -ne $SkipAgent })
        Write-Host "  [SKIP] $SkipAgent excluded -- running with $($agents.Count) agents" -ForegroundColor DarkYellow
    }

    # Check CLI availability and filter
    $availableAgents = @()
    foreach ($agent in $agents) {
        $cliAvailable = $null -ne (Get-Command $agent.Name -ErrorAction SilentlyContinue)
        if ($cliAvailable) {
            $availableAgents += $agent
        } else {
            Write-Host "  [!!] $($agent.Name) CLI not found -- skipping" -ForegroundColor DarkYellow
        }
    }
    $agents = $availableAgents

    if ($agents.Count -lt $minAgents) {
        $result.Error = "Only $($agents.Count) agents available (need $minAgents)"
        Write-Host "  [XX] $($result.Error)" -ForegroundColor Red
        return $result
    }

    # Build prompts per agent
    Write-Host "  [SCALES] Dispatching $($agents.Count) agents for independent extraction..." -ForegroundColor Cyan

    # Update file map if available
    if (Get-Command Update-FileMap -ErrorAction SilentlyContinue) {
        Update-FileMap -Root $RepoRoot -GsdPath $GsdDir 2>$null | Out-Null
    }

    $agentPrompts = @{}
    foreach ($agent in $agents) {
        $templatePath = Join-Path $promptDir $agent.Template
        if (-not (Test-Path $templatePath)) {
            Write-Host "  [XX] Template not found: $($agent.Template)" -ForegroundColor Red
            continue
        }

        $prompt = (Get-Content $templatePath -Raw)
        $prompt = $prompt.Replace("{{REPO_ROOT}}", $RepoRoot)
        $prompt = $prompt.Replace("{{GSD_DIR}}", $GsdDir)
        $prompt = $prompt.Replace("{{INTERFACE_CONTEXT}}", $InterfaceContext)

        # Append file map reference
        $fileTreePath = Join-Path $GsdDir "file-map-tree.md"
        if (Test-Path $fileTreePath) {
            $prompt += "`n`n## Repository File Map`nRead: $fileTreePath"
        }

        $agentPrompts[$agent.Name] = @{
            Prompt       = $prompt
            AllowedTools = $agent.AllowedTools
            GeminiMode   = $agent.GeminiMode
            LogFile      = Join-Path $logDir "council-requirements-$($agent.Name).log"
        }
    }

    if ($DryRun) {
        Write-Host "  [DRY RUN] Would dispatch $($agents.Count) extraction agents" -ForegroundColor DarkGray
        $result.Success = $true
        return $result
    }

    # Dispatch agents
    $completedAgents = @()
    $failedAgents = @()

    if ($UseJobs -and $agents.Count -gt 1) {
        # ── PARALLEL DISPATCH (PowerShell jobs) ──
        Write-Host "  [SCALES] Launching $($agents.Count) parallel extraction jobs..." -ForegroundColor Cyan

        $jobs = @{}
        foreach ($agent in $agents) {
            $entry = $agentPrompts[$agent.Name]
            if (-not $entry) { continue }

            Write-Host "    $($agent.Name.ToUpper()) -> extracting requirements" -ForegroundColor Magenta

            $jobs[$agent.Name] = Start-Job -ScriptBlock {
                param($GlobalDir, $Agent, $Prompt, $Phase, $LogFile, $GsdDir, $AllowedTools, $GeminiMode)
                . "$GlobalDir\lib\modules\resilience.ps1"
                $invokeParams = @{
                    Agent   = $Agent
                    Prompt  = $Prompt
                    Phase   = $Phase
                    LogFile = $LogFile
                    CurrentBatchSize = 1
                    GsdDir  = $GsdDir
                }
                if ($AllowedTools) { $invokeParams["AllowedTools"] = $AllowedTools }
                if ($GeminiMode)   { $invokeParams["GeminiMode"]   = $GeminiMode }
                Invoke-WithRetry @invokeParams
            } -ArgumentList @(
                $globalDir,
                $agent.Name,
                $entry.Prompt,
                "council-requirements",
                $entry.LogFile,
                $GsdDir,
                $entry.AllowedTools,
                $entry.GeminiMode
            )

            if ($cooldown -gt 0) { Start-Sleep -Seconds $cooldown }
        }

        # Wait for all jobs
        Write-Host "  [SCALES] Waiting for all extractions (timeout: ${timeout}s)..." -ForegroundColor Cyan

        foreach ($agentName in $jobs.Keys) {
            $job = $jobs[$agentName]
            try {
                $jobResult = $job | Wait-Job -Timeout $timeout | Receive-Job -ErrorAction SilentlyContinue
                $state = $job.State
                if ($state -eq "Completed") {
                    Write-Host "    [PASS] $($agentName) extraction completed" -ForegroundColor Green
                    $completedAgents += $agentName
                } else {
                    Write-Host "    [FAIL] $($agentName) extraction $state" -ForegroundColor Red
                    $failedAgents += $agentName
                }
            } catch {
                Write-Host "    [FAIL] $($agentName) extraction failed: $($_.Exception.Message)" -ForegroundColor Red
                $failedAgents += $agentName
            } finally {
                Remove-Job $job -Force -ErrorAction SilentlyContinue
            }
        }
    } else {
        # ── SEQUENTIAL DISPATCH ──
        foreach ($agent in $agents) {
            $entry = $agentPrompts[$agent.Name]
            if (-not $entry) { continue }

            Write-Host "    $($agent.Name.ToUpper()) -> extracting requirements..." -ForegroundColor Magenta
            try {
                $invokeParams = @{
                    Agent   = $agent.Name
                    Prompt  = $entry.Prompt
                    Phase   = "council-requirements"
                    LogFile = $entry.LogFile
                    CurrentBatchSize = 1
                    GsdDir  = $GsdDir
                }
                if ($entry.AllowedTools) { $invokeParams["AllowedTools"] = $entry.AllowedTools }
                if ($entry.GeminiMode)   { $invokeParams["GeminiMode"]   = $entry.GeminiMode }

                Invoke-WithRetry @invokeParams | Out-Null
                Write-Host "    [PASS] $($agent.Name) extraction completed" -ForegroundColor Green
                $completedAgents += $agent.Name
            } catch {
                Write-Host "    [FAIL] $($agent.Name) extraction failed: $($_.Exception.Message)" -ForegroundColor Red
                $failedAgents += $agent.Name
            }
        }
    }

    $result.AgentsSucceeded = $completedAgents.Count
    Write-Host ""
    Write-Host "  [SCALES] Extraction complete: $($completedAgents.Count)/$($agents.Count) agents succeeded" -ForegroundColor Cyan

    if ($completedAgents.Count -lt $minAgents) {
        $result.Error = "Only $($completedAgents.Count) agents succeeded (need $minAgents)"
        Write-Host "  [XX] $($result.Error)" -ForegroundColor Red
        return $result
    }

    # ── COLLECT AGENT OUTPUTS ──
    $agentOutputs = @{}
    foreach ($agentName in $completedAgents) {
        $extractPath = Join-Path $healthDir "council-extract-$agentName.json"
        if (Test-Path $extractPath) {
            try {
                $parsed = Get-Content $extractPath -Raw | ConvertFrom-Json
                if ($parsed.requirements -and @($parsed.requirements).Count -gt 0) {
                    $agentOutputs[$agentName] = $parsed
                    Write-Host "    $agentName found $(@($parsed.requirements).Count) requirements" -ForegroundColor DarkGray
                } else {
                    Write-Host "    $agentName output has no requirements" -ForegroundColor DarkYellow
                }
            } catch {
                Write-Host "    $agentName output not valid JSON" -ForegroundColor DarkYellow
            }
        } else {
            # Try parsing from log file
            $logPath = Join-Path $logDir "council-requirements-$agentName.log"
            if (Test-Path $logPath) {
                $logContent = Get-Content $logPath -Raw -ErrorAction SilentlyContinue
                if ($logContent -match '\{[\s\S]*"requirements"\s*:\s*\[[\s\S]*\][\s\S]*\}') {
                    try {
                        $parsed = $Matches[0] | ConvertFrom-Json
                        if ($parsed.requirements) {
                            $agentOutputs[$agentName] = $parsed
                            Write-Host "    $agentName found $(@($parsed.requirements).Count) requirements (from log)" -ForegroundColor DarkGray
                        }
                    } catch {}
                }
            }
        }
    }

    if ($agentOutputs.Count -lt $minAgents) {
        # Check if we have at least 1 usable output
        if ($agentOutputs.Count -eq 1) {
            Write-Host "  [WARN] Only 1 agent produced valid output -- using as-is (all confidence = low)" -ForegroundColor DarkYellow
        } elseif ($agentOutputs.Count -eq 0) {
            $result.Error = "No agent produced valid requirement output"
            Write-Host "  [XX] $($result.Error)" -ForegroundColor Red
            return $result
        }
    }

    # ── SYNTHESIS (Claude merges all outputs) ──
    Write-Host "  [SCALES] Claude synthesizing merged requirements matrix..." -ForegroundColor Cyan

    $isPartial = $agentOutputs.Count -lt 3
    $synthTemplateName = if ($isPartial) { "requirements-synthesize-partial.md" } else { "requirements-synthesize.md" }
    $synthTemplatePath = Join-Path $promptDir $synthTemplateName

    if (-not (Test-Path $synthTemplatePath)) {
        # Fall back to full template
        $synthTemplatePath = Join-Path $promptDir "requirements-synthesize.md"
    }

    $synthPrompt = if (Test-Path $synthTemplatePath) {
        (Get-Content $synthTemplatePath -Raw)
    } else {
        "Read the agent extraction files below. Merge, deduplicate, and write requirements-matrix.json to {{GSD_DIR}}\health\requirements-matrix.json"
    }

    $synthPrompt = $synthPrompt.Replace("{{GSD_DIR}}", $GsdDir)
    $synthPrompt = $synthPrompt.Replace("{{AGENT_COUNT}}", "$($agentOutputs.Count)")

    # Build agent output section
    $outputSection = ""
    foreach ($agentName in $agentOutputs.Keys) {
        $extractPath = Join-Path $healthDir "council-extract-$agentName.json"
        if (Test-Path $extractPath) {
            $outputSection += "`n## $($agentName.ToUpper()) Extraction`nRead: $extractPath`n"
        }
    }
    $synthPrompt = $synthPrompt.Replace("{{AGENT_OUTPUTS}}", $outputSection)

    # Handle partial template placeholders
    if ($isPartial) {
        $missing = @("claude", "codex", "gemini") | Where-Object { $_ -notin $agentOutputs.Keys }
        $synthPrompt = $synthPrompt.Replace("{{MISSING_AGENT}}", ($missing -join ", "))
    }

    $synthLogFile = Join-Path $logDir "council-requirements-synthesis.log"

    $synthResult = Invoke-WithRetry -Agent "claude" -Prompt $synthPrompt -Phase "council-requirements-synthesis" `
        -LogFile $synthLogFile -MaxAttempts 2 -CurrentBatchSize 1 -GsdDir $GsdDir `
        -AllowedTools "Read,Write"

    # Verify matrix was written
    $matrixPath = Join-Path $healthDir "requirements-matrix.json"
    if (Test-Path $matrixPath) {
        try {
            $matrix = Get-Content $matrixPath -Raw | ConvertFrom-Json
            if ($matrix.requirements -and @($matrix.requirements).Count -gt 0) {
                $result.Success = $true
                Write-Host "  [OK] Requirements matrix: $(@($matrix.requirements).Count) requirements" -ForegroundColor Green
                Write-Host "  [OK] Health: $($matrix.meta.health_score)%" -ForegroundColor Green
            } else {
                # Synthesis wrote the file but it's empty -- try local merge
                Write-Host "  [WARN] Synthesis produced empty matrix -- trying local merge" -ForegroundColor DarkYellow
                $localResult = Merge-CouncilRequirementsLocal -AgentOutputs $agentOutputs -GsdDir $GsdDir
                $result.Success = $localResult.Success
            }
        } catch {
            Write-Host "  [WARN] Matrix file invalid -- trying local merge" -ForegroundColor DarkYellow
            $localResult = Merge-CouncilRequirementsLocal -AgentOutputs $agentOutputs -GsdDir $GsdDir
            $result.Success = $localResult.Success
        }
    } else {
        # Synthesis didn't write the file -- try local merge
        Write-Host "  [WARN] Synthesis did not write matrix -- trying local merge" -ForegroundColor DarkYellow
        $localResult = Merge-CouncilRequirementsLocal -AgentOutputs $agentOutputs -GsdDir $GsdDir
        $result.Success = $localResult.Success
    }

    return $result
}


function Merge-CouncilRequirementsLocal {
    <#
    .SYNOPSIS
        Local PowerShell fallback: merges agent outputs using token-overlap deduplication
        when the Claude synthesis agent fails or produces invalid output.
    #>
    param(
        [hashtable]$AgentOutputs,
        [string]$GsdDir
    )

    $result = @{ Success = $false }

    # Collect all requirements
    $allReqs = @()
    foreach ($agentName in $AgentOutputs.Keys) {
        $output = $AgentOutputs[$agentName]
        foreach ($req in @($output.requirements)) {
            $allReqs += @{
                Agent       = $agentName
                Description = $req.description
                Source      = $req.source
                SpecDoc     = $req.spec_doc
                SdlcPhase   = $req.sdlc_phase
                Pattern     = $req.pattern
                Priority    = $req.priority
                Status      = $req.status
                SatisfiedBy = $req.satisfied_by
                Notes       = $req.notes
            }
        }
    }

    if ($allReqs.Count -eq 0) {
        Write-Host "  [XX] No requirements to merge" -ForegroundColor Red
        return $result
    }

    # Simple deduplication: group by spec_doc + normalized description keywords
    $groups = @()
    $assigned = @{}

    for ($i = 0; $i -lt $allReqs.Count; $i++) {
        if ($assigned.ContainsKey($i)) { continue }

        $group = @($allReqs[$i])
        $assigned[$i] = $true

        $descA = $allReqs[$i].Description.ToLower() -replace '[^a-z0-9\s]', ''
        $tokensA = @($descA -split '\s+' | Where-Object { $_.Length -gt 2 })

        for ($j = $i + 1; $j -lt $allReqs.Count; $j++) {
            if ($assigned.ContainsKey($j)) { continue }

            $descB = $allReqs[$j].Description.ToLower() -replace '[^a-z0-9\s]', ''
            $tokensB = @($descB -split '\s+' | Where-Object { $_.Length -gt 2 })

            # Calculate token overlap (Jaccard similarity)
            if ($tokensA.Count -gt 0 -and $tokensB.Count -gt 0) {
                $setA = [System.Collections.Generic.HashSet[string]]::new([string[]]$tokensA)
                $setB = [System.Collections.Generic.HashSet[string]]::new([string[]]$tokensB)
                $intersection = [System.Collections.Generic.HashSet[string]]::new($setA)
                $intersection.IntersectWith($setB)
                $union = [System.Collections.Generic.HashSet[string]]::new($setA)
                $union.UnionWith($setB)
                $similarity = if ($union.Count -gt 0) { $intersection.Count / $union.Count } else { 0 }

                if ($similarity -gt 0.5) {
                    $group += $allReqs[$j]
                    $assigned[$j] = $true
                }
            }
        }

        $groups += ,@($group)
    }

    # Merge each group into one requirement
    $mergedReqs = @()
    $reqNum = 1

    $priorityRank = @{ "high" = 3; "medium" = 2; "low" = 1 }
    $statusRank   = @{ "not_started" = 3; "partial" = 2; "satisfied" = 1 }

    foreach ($group in $groups) {
        # Use longest description
        $bestDesc = ($group | Sort-Object { $_.Description.Length } -Descending | Select-Object -First 1).Description

        # Most conservative status
        $bestStatus = "satisfied"
        foreach ($member in $group) {
            $s = $member.Status
            if ($s -and $statusRank.ContainsKey($s) -and $statusRank[$s] -gt $statusRank[$bestStatus]) {
                $bestStatus = $s
            }
        }

        # Highest priority
        $bestPriority = "low"
        foreach ($member in $group) {
            $p = $member.Priority
            if ($p -and $priorityRank.ContainsKey($p) -and $priorityRank[$p] -gt $priorityRank[$bestPriority]) {
                $bestPriority = $p
            }
        }

        # Track which agents found this
        $foundBy = @($group | ForEach-Object { $_.Agent } | Select-Object -Unique)
        $confidence = switch ($foundBy.Count) {
            3       { "high" }
            2       { "medium" }
            default { "low" }
        }

        $id = "REQ-{0:D3}" -f $reqNum
        $mergedReqs += [PSCustomObject]@{
            id           = $id
            description  = $bestDesc
            source       = ($group[0].Source)
            spec_doc     = ($group[0].SpecDoc)
            sdlc_phase   = ($group[0].SdlcPhase)
            pattern      = ($group[0].Pattern)
            priority     = $bestPriority
            status       = $bestStatus
            satisfied_by = ($group | Where-Object { $_.SatisfiedBy } | Select-Object -First 1 -ExpandProperty SatisfiedBy)
            notes        = ($group | Where-Object { $_.Notes } | Select-Object -First 1 -ExpandProperty Notes)
            confidence   = $confidence
            found_by     = $foundBy
        }
        $reqNum++
    }

    # Calculate stats
    $total = $mergedReqs.Count
    $satisfied = @($mergedReqs | Where-Object { $_.status -eq "satisfied" }).Count
    $partial = @($mergedReqs | Where-Object { $_.status -eq "partial" }).Count
    $notStarted = @($mergedReqs | Where-Object { $_.status -eq "not_started" }).Count
    $healthScore = if ($total -gt 0) { [math]::Round(($satisfied / $total) * 100, 1) } else { 0 }

    # Write matrix
    $matrix = [PSCustomObject]@{
        meta = [PSCustomObject]@{
            total_requirements = $total
            satisfied          = $satisfied
            partial            = $partial
            not_started        = $notStarted
            health_score       = $healthScore
            iteration          = 0
            extraction_method  = "council-local-merge"
            agents_participated = @($AgentOutputs.Keys | Sort-Object)
            timestamp          = (Get-Date).ToUniversalTime().ToString("o")
        }
        requirements = $mergedReqs
    }

    $matrixPath = Join-Path $GsdDir "health\requirements-matrix.json"
    $matrix | ConvertTo-Json -Depth 10 | Set-Content $matrixPath -Encoding UTF8

    # Write health
    $healthPath = Join-Path $GsdDir "health\health-current.json"
    @{
        health_score = $healthScore; total_requirements = $total
        satisfied = $satisfied; partial = $partial; not_started = $notStarted; iteration = 0
    } | ConvertTo-Json | Set-Content $healthPath -Encoding UTF8

    # Write report
    $high = @($mergedReqs | Where-Object { $_.confidence -eq "high" }).Count
    $med = @($mergedReqs | Where-Object { $_.confidence -eq "medium" }).Count
    $low = @($mergedReqs | Where-Object { $_.confidence -eq "low" }).Count

    $report = @(
        "# Council Requirements Report (Local Merge)"
        ""
        "| Metric | Value |"
        "|--------|-------|"
        "| Total requirements | $total |"
        "| High confidence | $high |"
        "| Medium confidence | $med |"
        "| Low confidence | $low |"
        "| Agents participated | $($AgentOutputs.Keys -join ', ') |"
        "| Health score | ${healthScore}% |"
        ""
    )

    if ($low -gt 0) {
        $report += "## Low Confidence (review needed)"
        $report += "| ID | Description | Found By |"
        $report += "|----|-------------|----------|"
        foreach ($req in ($mergedReqs | Where-Object { $_.confidence -eq "low" })) {
            $report += "| $($req.id) | $($req.description) | $($req.found_by -join ', ') |"
        }
        $report += ""
    }

    $reportPath = Join-Path $GsdDir "health\council-requirements-report.md"
    ($report -join "`n") | Set-Content $reportPath -Encoding UTF8

    Write-Host "  [OK] Local merge: $total requirements (${healthScore}% health)" -ForegroundColor Green
    $result.Success = $true
    return $result
}

Write-Host "  Council Requirements module loaded." -ForegroundColor DarkGray
'@

# Append to resilience library
$resiliencePath = "$GsdGlobalDir\lib\modules\resilience.ps1"
$existingResilience = Get-Content $resiliencePath -Raw
if ($existingResilience -notlike "*function Invoke-CouncilRequirements*") {
    Add-Content -Path $resiliencePath -Value $councilReqCode -Encoding UTF8
    Write-Host "[OK] Council Requirements module appended to resilience.ps1" -ForegroundColor Green
} else {
    Write-Host "[SKIP] Council Requirements module already in resilience.ps1" -ForegroundColor DarkGray
}

# ========================================================
# 4. Add gsd-verify-requirements to profile functions
# ========================================================

Write-Host ""
Write-Host "[CLIP] Adding gsd-verify-requirements command..." -ForegroundColor Yellow

$profileFunctions = Join-Path $GsdGlobalDir "scripts\gsd-profile-functions.ps1"
if (Test-Path $profileFunctions) {
    $pfContent = Get-Content $profileFunctions -Raw

    if ($pfContent -notlike "*function gsd-verify-requirements*") {
        $verifyFunction = @'

function gsd-verify-requirements {
    <#
    .SYNOPSIS
        3-agent council requirements extraction and verification.
        Run from any repo directory to extract, deduplicate, and confidence-score
        all requirements using Claude, Codex, and Gemini independently.
    .EXAMPLE
        gsd-verify-requirements
        gsd-verify-requirements -DryRun
        gsd-verify-requirements -SkipAgent gemini
        gsd-verify-requirements -Sequential
        gsd-verify-requirements -PreserveExisting
    #>
    param(
        [string]$SkipAgent = "",
        [switch]$Sequential,
        [switch]$DryRun,
        [switch]$PreserveExisting
    )

    $repoRoot = (Get-Location).Path
    $gsdDir = Join-Path $repoRoot ".gsd"
    $globalDir = Join-Path $env:USERPROFILE ".gsd-global"

    # Ensure .gsd directory structure
    @($gsdDir, "$gsdDir\health", "$gsdDir\logs", "$gsdDir\specs",
      "$gsdDir\code-review", "$gsdDir\research", "$gsdDir\generation-queue",
      "$gsdDir\agent-handoff") | ForEach-Object {
        if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
    }

    # Initialize health if missing
    $healthFile = Join-Path $gsdDir "health\health-current.json"
    if (-not (Test-Path $healthFile)) {
        @{ health_score=0; total_requirements=0; satisfied=0; partial=0; not_started=0; iteration=0 } |
            ConvertTo-Json | Set-Content $healthFile -Encoding UTF8
    }

    # Load resilience module
    . "$globalDir\lib\modules\resilience.ps1"
    if (Test-Path "$globalDir\lib\modules\interfaces.ps1") { . "$globalDir\lib\modules\interfaces.ps1" }
    if (Test-Path "$globalDir\lib\modules\interface-wrapper.ps1") { . "$globalDir\lib\modules\interface-wrapper.ps1" }

    # Banner
    Write-Host ""
    Write-Host "=========================================================" -ForegroundColor Cyan
    Write-Host "  GSD Council Requirements Verification" -ForegroundColor Cyan
    Write-Host "  3-Agent Independent Extraction + Synthesis" -ForegroundColor Cyan
    Write-Host "=========================================================" -ForegroundColor Cyan
    Write-Host "  Repo: $repoRoot" -ForegroundColor White
    Write-Host ""

    # Pre-flight: check CLIs
    $cliChecks = @("claude", "codex", "gemini") | Where-Object { $_ -ne $SkipAgent }
    foreach ($cli in $cliChecks) {
        $available = $null -ne (Get-Command $cli -ErrorAction SilentlyContinue)
        if ($available) {
            Write-Host "  [OK] $cli available" -ForegroundColor Green
        } else {
            Write-Host "  [!!] $cli not found (optional)" -ForegroundColor DarkYellow
        }
    }
    Write-Host ""

    # Backup existing matrix if PreserveExisting
    $matrixFile = Join-Path $gsdDir "health\requirements-matrix.json"
    if ($PreserveExisting -and (Test-Path $matrixFile)) {
        $backupPath = "$matrixFile.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item $matrixFile $backupPath
        Write-Host "  [OK] Existing matrix backed up" -ForegroundColor DarkGreen
    }

    # Generate file map
    if (Get-Command Update-FileMap -ErrorAction SilentlyContinue) {
        Write-Host "  [MAP] Generating file map..." -ForegroundColor DarkGray
        Update-FileMap -Root $repoRoot -GsdPath $gsdDir 2>$null | Out-Null
    }

    # Run council extraction
    $useJobs = -not $Sequential
    $callResult = Invoke-CouncilRequirements -RepoRoot $repoRoot -GsdDir $gsdDir `
        -DryRun:$DryRun -UseJobs $useJobs -SkipAgent $SkipAgent

    # Report results
    Write-Host ""
    if ($callResult.Success -and -not $DryRun -and (Test-Path $matrixFile)) {
        $matrix = Get-Content $matrixFile -Raw | ConvertFrom-Json
        Write-Host "  ========================================" -ForegroundColor Green
        Write-Host "  REQUIREMENTS VERIFIED SUCCESSFULLY" -ForegroundColor Green
        Write-Host "  ========================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "  Total:      $($matrix.meta.total_requirements) requirements" -ForegroundColor White
        Write-Host "  Health:     $($matrix.meta.health_score)%" -ForegroundColor White
        Write-Host "  Agents:     $($callResult.AgentsSucceeded) participated" -ForegroundColor White
        Write-Host ""

        $high = @($matrix.requirements | Where-Object { $_.confidence -eq "high" }).Count
        $med  = @($matrix.requirements | Where-Object { $_.confidence -eq "medium" }).Count
        $low  = @($matrix.requirements | Where-Object { $_.confidence -eq "low" }).Count

        Write-Host "  Confidence:" -ForegroundColor Yellow
        Write-Host "    High:   $high (found by all agents)" -ForegroundColor Green
        Write-Host "    Medium: $med (found by 2 agents)" -ForegroundColor Yellow
        Write-Host "    Low:    $low (review needed - single agent)" -ForegroundColor Red
        Write-Host ""

        Write-Host "  Output:" -ForegroundColor DarkGray
        Write-Host "    Matrix: $matrixFile" -ForegroundColor DarkGray
        Write-Host "    Report: $(Join-Path $gsdDir 'health\council-requirements-report.md')" -ForegroundColor DarkGray
        Write-Host ""
    } elseif ($callResult.Success -and $DryRun) {
        Write-Host "  [DRY RUN] Pre-flight passed. All agents available." -ForegroundColor Green
        Write-Host "  Run without -DryRun to execute extraction." -ForegroundColor DarkGray
        Write-Host ""
    } else {
        Write-Host "  [FAIL] Requirements extraction failed" -ForegroundColor Red
        Write-Host "  Error: $($callResult.Error)" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Try:" -ForegroundColor DarkGray
        Write-Host "    gsd-verify-requirements -Sequential    # Run one at a time" -ForegroundColor DarkGray
        Write-Host "    gsd-verify-requirements -SkipAgent gemini  # Skip unavailable agent" -ForegroundColor DarkGray
    }
}
'@

        Add-Content -Path $profileFunctions -Value $verifyFunction -Encoding UTF8
        Write-Host "  [OK] Added gsd-verify-requirements to profile functions" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] gsd-verify-requirements already exists" -ForegroundColor DarkGray
    }
}

# ========================================================
# 5. Patch convergence pipeline Phase 0
# ========================================================

Write-Host ""
Write-Host "[SYNC] Patching convergence pipeline for council Phase 0..." -ForegroundColor Yellow

$convergenceScript = Join-Path $GsdGlobalDir "scripts\convergence-loop.ps1"
if (Test-Path $convergenceScript) {
    $convContent = Get-Content $convergenceScript -Raw

    if ($convContent -notlike "*council-create-phases*") {
        # Replace the Phase 0 header with council-aware version
        $oldLine = '    Write-Host "[CLIP] Phase 0: CREATE PHASES" -ForegroundColor Magenta'
        $newBlock = @'
    Write-Host "[CLIP] Phase 0: CREATE PHASES" -ForegroundColor Magenta

    # Check if council requirements extraction is enabled
    $useCouncilReqs = $false
    if (Get-Command Invoke-CouncilRequirements -ErrorAction SilentlyContinue) {
        $crCfgPath = Join-Path $GlobalDir "config\global-config.json"
        if (Test-Path $crCfgPath) {
            try {
                $crCfg = (Get-Content $crCfgPath -Raw | ConvertFrom-Json).council_requirements
                if ($crCfg -and $crCfg.enabled) { $useCouncilReqs = $true }
            } catch {}
        }
    }

    if ($useCouncilReqs -and -not $DryRun) {
        Write-Host "  [SCALES] Council requirements extraction (3-agent parallel)" -ForegroundColor Cyan
        Save-Checkpoint -GsdDir $GsdDir -Pipeline "converge" -Iteration 0 -Phase "council-create-phases" -Health 0 -BatchSize $CurrentBatchSize
        $crResult = Invoke-CouncilRequirements -RepoRoot $RepoRoot -GsdDir $GsdDir
        if (-not $crResult.Success) {
            Write-Host "  [WARN] Council extraction failed. Falling back to single-agent." -ForegroundColor Yellow
            $useCouncilReqs = $false
        }
    }

    if (-not $useCouncilReqs) {
'@

        # Find and replace the Phase 0 header, then close the if block after the invoke
        if ($convContent -like "*Phase 0: CREATE PHASES*") {
            $convContent = $convContent.Replace($oldLine, $newBlock)

            # Add closing brace after the Out-Null line for the single-agent path
            $outNullLine = '            -LogFile "$GsdDir\logs\phase0.log" -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir | Out-Null'
            $convContent = $convContent.Replace($outNullLine, "$outNullLine`n    }")

            Set-Content -Path $convergenceScript -Value $convContent -Encoding UTF8
            Write-Host "  [OK] Convergence pipeline Phase 0 patched with council alternative" -ForegroundColor Green
        } else {
            Write-Host "  [WARN] Could not locate Phase 0 in convergence-loop.ps1 -- manual patch needed" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  [SKIP] Council Phase 0 already patched" -ForegroundColor DarkGray
    }
} else {
    Write-Host "  [SKIP] convergence-loop.ps1 not found" -ForegroundColor DarkGray
}

# ========================================================
# Done
# ========================================================

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Green
Write-Host "  Council Requirements Verification installed!" -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Usage:" -ForegroundColor White
Write-Host "    cd <your-project-directory>" -ForegroundColor DarkGray
Write-Host "    gsd-verify-requirements                     # 3-agent parallel extraction" -ForegroundColor DarkGray
Write-Host "    gsd-verify-requirements -Sequential         # One agent at a time" -ForegroundColor DarkGray
Write-Host "    gsd-verify-requirements -DryRun             # Preview without running" -ForegroundColor DarkGray
Write-Host "    gsd-verify-requirements -SkipAgent gemini   # Skip unavailable agent" -ForegroundColor DarkGray
Write-Host "    gsd-verify-requirements -PreserveExisting   # Merge into existing matrix" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Also auto-runs in convergence pipeline Phase 0 when council_requirements.enabled = true" -ForegroundColor DarkGray
Write-Host ""
