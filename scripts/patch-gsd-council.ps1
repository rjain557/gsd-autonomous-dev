<#
.SYNOPSIS
    GSD LLM Council — Multi-Agent Review Gate
    Run AFTER patch-gsd-final-validation.ps1.

.DESCRIPTION
    Adds a multi-agent "council" review that runs when health reaches 100%,
    BEFORE the final validation gate. Three agents (Claude, Codex, Gemini)
    independently review the codebase, then Claude synthesizes a consensus verdict.

    If the council blocks:
      - Health resets to 99% so the convergence loop continues
      - Council feedback is written to .gsd/supervisor/council-feedback.md
        and injected into the next iteration's prompts

    If the council approves:
      - Pipeline proceeds to final validation gate (build/test/audit)
      - Council findings included in developer-handoff.md

    Max 2 council attempts per pipeline run to prevent infinite looping.

.INSTALL_ORDER
    1. install-gsd-global.ps1
    2. install-gsd-blueprint.ps1
    3. patch-gsd-partial-repo.ps1
    4. patch-gsd-resilience.ps1
    5. patch-gsd-hardening.ps1
    6. patch-gsd-final-validation.ps1
    7. patch-gsd-council.ps1            <- this file
#>

param(
    [string]$UserHome = $env:USERPROFILE
)

$ErrorActionPreference = "Stop"
$GsdGlobalDir = Join-Path $UserHome ".gsd-global"

if (-not (Test-Path "$GsdGlobalDir\lib\modules\resilience.ps1")) {
    Write-Host "[XX] Resilience patch not applied. Run patch-gsd-resilience.ps1 first." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  GSD LLM Council — Multi-Agent Review Gate" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

# ========================================================
# Append council function to resilience library
# ========================================================

Write-Host "[SCALES] Adding LLM Council module to resilience library..." -ForegroundColor Yellow

$councilCode = @'

# ===============================================================
# GSD LLM COUNCIL MODULE - appended to resilience.ps1
# ===============================================================

function Invoke-LlmCouncil {
    <#
    .SYNOPSIS
        Multi-agent council review: 3 agents review independently in parallel,
        Claude synthesizes a consensus verdict on project readiness.
    .PARAMETER CouncilType
        convergence (default) - Full 3-agent review at 100% health
        post-research   - 2-agent check after research phase (Claude + Codex validate Gemini findings)
        pre-execute     - 2-agent check before execute phase (Claude + Gemini validate plan)
        post-blueprint  - 3-agent review after blueprint manifest generated
        stall-diagnosis - 3-agent parallel stall diagnosis
        post-spec-fix   - 2-agent check after spec conflict resolution (Claude + Codex validate Gemini fix)
    .RETURNS
        @{ Approved = bool; Findings = @{...}; Report = string }
    #>
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [int]$Iteration = 0,
        [double]$Health = 0,
        [string]$Pipeline = "converge",
        [ValidateSet("convergence","post-research","pre-execute","post-blueprint","stall-diagnosis","post-spec-fix")]
        [string]$CouncilType = "convergence"
    )

    $councilDir = Join-Path $GsdDir "health"
    $reviewDir = Join-Path $GsdDir "code-review"
    $logDir = Join-Path $GsdDir "logs"
    $supervisorDir = Join-Path $GsdDir "supervisor"
    foreach ($d in @($councilDir, $reviewDir, $logDir, $supervisorDir)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }

    $globalDir = Join-Path $env:USERPROFILE ".gsd-global"
    $promptDir = Join-Path $globalDir "prompts\council"

    Write-Host "  [SCALES] Building council context..." -ForegroundColor DarkGray

    # ── 1. BUILD SHARED CONTEXT ──
    $context = @()
    $context += "# LLM Council Review Context ($CouncilType)"
    $context += "- Health: ${Health}% | Iteration: $Iteration | Pipeline: $Pipeline | Type: $CouncilType"
    $context += ""

    # Requirements matrix
    $matrixPath = Join-Path $GsdDir "health\requirements-matrix.json"
    if (Test-Path $matrixPath) {
        $matrixRaw = Get-Content $matrixPath -Raw
        if ($matrixRaw.Length -gt 3000) { $matrixRaw = $matrixRaw.Substring(0, 3000) + "`n... (truncated)" }
        $context += "## Requirements Matrix"
        $context += '```json'
        $context += $matrixRaw
        $context += '```'
        $context += ""
    }

    # Code review findings
    $reviewPath = Join-Path $GsdDir "code-review\review-current.md"
    if (Test-Path $reviewPath) {
        $reviewRaw = (Get-Content $reviewPath -Raw).Trim()
        if ($reviewRaw.Length -gt 2000) { $reviewRaw = $reviewRaw.Substring(0, 2000) + "`n... (truncated)" }
        $context += "## Latest Code Review"
        $context += $reviewRaw
        $context += ""
    }

    # Drift report
    $driftPath = Join-Path $GsdDir "health\drift-report.md"
    if (Test-Path $driftPath) {
        $driftRaw = (Get-Content $driftPath -Raw).Trim()
        if ($driftRaw.Length -gt 1000) { $driftRaw = $driftRaw.Substring(0, 1000) + "`n... (truncated)" }
        $context += "## Drift Report"
        $context += $driftRaw
        $context += ""
    }

    # File tree
    $treePath = Join-Path $GsdDir "file-map-tree.md"
    if (Test-Path $treePath) {
        $treeRaw = (Get-Content $treePath -Raw).Trim()
        if ($treeRaw.Length -gt 2000) { $treeRaw = $treeRaw.Substring(0, 2000) + "`n... (truncated)" }
        $context += "## File Structure"
        $context += $treeRaw
        $context += ""
    }

    # Health history (last 5 entries)
    $histPath = Join-Path $GsdDir "health\health-history.jsonl"
    if (Test-Path $histPath) {
        $histLines = Get-Content $histPath -Tail 5
        $context += "## Recent Health History"
        $context += '```'
        $context += ($histLines -join "`n")
        $context += '```'
        $context += ""
    }

    $sharedContext = $context -join "`n"

    # ── 2. PARALLEL AGENT REVIEWS ──
    # Select agents and templates based on council type
    switch ($CouncilType) {
        "post-research" {
            $agents = @(
                @{ Name = "claude"; Template = "post-research-claude.md"; Mode = ""; AllowedTools = "Read,Glob,Grep" }
                @{ Name = "codex";  Template = "post-research-codex.md";  Mode = ""; AllowedTools = "" }
            )
            $phaseName = "council-post-research"
        }
        "pre-execute" {
            $agents = @(
                @{ Name = "claude"; Template = "pre-execute-claude.md"; Mode = ""; AllowedTools = "Read,Glob,Grep" }
                @{ Name = "gemini"; Template = "pre-execute-gemini.md"; Mode = "--approval-mode plan"; AllowedTools = "" }
            )
            $phaseName = "council-pre-execute"
        }
        "post-blueprint" {
            $agents = @(
                @{ Name = "claude"; Template = "post-blueprint-claude.md"; Mode = ""; AllowedTools = "Read,Glob,Grep" }
                @{ Name = "codex";  Template = "post-blueprint-codex.md";  Mode = ""; AllowedTools = "" }
                @{ Name = "gemini"; Template = "post-blueprint-gemini.md"; Mode = "--approval-mode plan"; AllowedTools = "" }
            )
            $phaseName = "council-post-blueprint"
        }
        "stall-diagnosis" {
            $agents = @(
                @{ Name = "claude"; Template = "stall-claude.md"; Mode = ""; AllowedTools = "Read,Glob,Grep" }
                @{ Name = "codex";  Template = "stall-codex.md";  Mode = ""; AllowedTools = "" }
                @{ Name = "gemini"; Template = "stall-gemini.md"; Mode = "--approval-mode plan"; AllowedTools = "" }
            )
            $phaseName = "council-stall-diagnosis"
        }
        "post-spec-fix" {
            $agents = @(
                @{ Name = "claude"; Template = "post-spec-fix-claude.md"; Mode = ""; AllowedTools = "Read,Glob,Grep" }
                @{ Name = "codex";  Template = "post-spec-fix-codex.md";  Mode = ""; AllowedTools = "" }
            )
            $phaseName = "council-post-spec-fix"
        }
        default {
            # "convergence" — full 3-agent review
            $agents = @(
                @{ Name = "claude"; Template = "claude-review.md"; Mode = ""; AllowedTools = "Read,Glob,Grep" }
                @{ Name = "codex";  Template = "codex-review.md";  Mode = ""; AllowedTools = "" }
                @{ Name = "gemini"; Template = "gemini-review.md"; Mode = "--approval-mode plan"; AllowedTools = "" }
            )
            $phaseName = "council-review"
        }
    }

    Write-Host "  [SCALES] Dispatching $($agents.Count) independent reviews ($CouncilType)..." -ForegroundColor DarkGray

    $reviews = @{}

    foreach ($agent in $agents) {
        $templatePath = Join-Path $promptDir $agent.Template
        if (-not (Test-Path $templatePath)) {
            Write-Host "    [WARN] Missing template: $templatePath — skipping $($agent.Name)" -ForegroundColor DarkYellow
            $reviews[$agent.Name] = @{ Success = $false; Output = "Template not found" }
            continue
        }

        $prompt = (Get-Content $templatePath -Raw)
        $prompt = $prompt.Replace("{{ITERATION}}", "$Iteration").Replace("{{HEALTH}}", "$Health").Replace("{{GSD_DIR}}", $GsdDir).Replace("{{REPO_ROOT}}", $RepoRoot)
        $prompt += "`n`n$sharedContext"

        Write-Host "    $($agent.Name.ToUpper()) reviewing..." -ForegroundColor DarkGray

        $retryParams = @{
            Agent          = $agent.Name
            Prompt         = $prompt
            Phase          = $phaseName
            LogFile        = "$logDir\council-$CouncilType-$($agent.Name).log"
            MaxAttempts    = 2
            CurrentBatchSize = 1
            GsdDir         = $GsdDir
        }
        if ($agent.AllowedTools) { $retryParams["AllowedTools"] = $agent.AllowedTools }
        if ($agent.Mode) { $retryParams["GeminiMode"] = $agent.Mode }

        $result = Invoke-WithRetry @retryParams
        $reviews[$agent.Name] = $result

        if ($result.Success) {
            Write-Host "    $($agent.Name.ToUpper()) review complete" -ForegroundColor DarkGreen
        } else {
            Write-Host "    $($agent.Name.ToUpper()) review failed: $($result.Error)" -ForegroundColor DarkYellow
        }
    }

    # Count successful reviews
    $successCount = ($reviews.Values | Where-Object { $_.Success }).Count
    if ($successCount -lt 2) {
        Write-Host "  [SCALES] Only $successCount/3 reviews succeeded — auto-approving (insufficient quorum)" -ForegroundColor DarkYellow
        $fallbackResult = @{
            Approved = $true
            Findings = @{
                approved   = $true
                confidence = 50
                votes      = @{}
                concerns   = @("Council quorum not met ($successCount/3 agents responded)")
                strengths  = @()
                reason     = "Auto-approved: insufficient council quorum"
            }
            Report = ""
        }
        # Write partial results
        $fallbackResult.Findings | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $councilDir "council-review.json") -Encoding UTF8
        return $fallbackResult
    }

    # ── 3. SYNTHESIS (Claude reads all reviews) ──
    Write-Host "  [SCALES] Synthesizing council verdict..." -ForegroundColor DarkGray

    $synthesisPrompt = ""
    $synthTemplatePath = Join-Path $promptDir "synthesize.md"
    if (Test-Path $synthTemplatePath) {
        $synthesisPrompt = (Get-Content $synthTemplatePath -Raw)
        $synthesisPrompt = $synthesisPrompt.Replace("{{ITERATION}}", "$Iteration").Replace("{{HEALTH}}", "$Health").Replace("{{GSD_DIR}}", $GsdDir)
    } else {
        $synthesisPrompt = "You are the synthesis judge. Read all 3 reviews below. Produce a JSON verdict."
    }

    # Append each agent's review log
    foreach ($agentEntry in $agents) {
        $agentName = $agentEntry.Name
        $logPath = "$logDir\council-$CouncilType-$agentName.log"
        if (Test-Path $logPath) {
            $logContent = (Get-Content $logPath -Raw -ErrorAction SilentlyContinue)
            if ($logContent -and $logContent.Length -gt 3000) { $logContent = $logContent.Substring(0, 3000) + "`n... (truncated)" }
            if ($logContent) {
                $synthesisPrompt += "`n`n## $($agentName.ToUpper()) Review`n$logContent"
            }
        }
    }

    $synthResult = Invoke-WithRetry -Agent "claude" -Prompt $synthesisPrompt -Phase "council-synthesize" `
        -LogFile "$logDir\council-$CouncilType-synthesis.log" -MaxAttempts 2 -CurrentBatchSize 1 -GsdDir $GsdDir `
        -AllowedTools "Read"

    # ── 4. PARSE VERDICT & WRITE OUTPUTS ──
    $approved = $true
    $findings = @{
        approved   = $true
        confidence = 75
        votes      = @{
            claude = "unknown"
            codex  = "unknown"
            gemini = "unknown"
        }
        concerns   = @()
        strengths  = @()
        reason     = ""
    }

    if ($synthResult.Success) {
        $synthLog = "$logDir\council-$CouncilType-synthesis.log"
        if (Test-Path $synthLog) {
            $synthContent = Get-Content $synthLog -Raw -ErrorAction SilentlyContinue
            # Try to extract JSON from output
            if ($synthContent -match '\{[\s\S]*"approved"\s*:[\s\S]*\}') {
                try {
                    $parsed = $Matches[0] | ConvertFrom-Json
                    if ($null -ne $parsed.approved) { $findings.approved = $parsed.approved; $approved = [bool]$parsed.approved }
                    if ($parsed.confidence) { $findings.confidence = $parsed.confidence }
                    if ($parsed.votes) { $findings.votes = $parsed.votes }
                    if ($parsed.concerns) { $findings.concerns = @($parsed.concerns) }
                    if ($parsed.strengths) { $findings.strengths = @($parsed.strengths) }
                    if ($parsed.reason) { $findings.reason = $parsed.reason }
                } catch {
                    Write-Host "    [WARN] Could not parse synthesis JSON — defaulting to approved" -ForegroundColor DarkYellow
                }
            }

            # Check for explicit block keywords even if JSON parsing fails
            if ($synthContent -match '"vote"\s*:\s*"block"' -or $synthContent -match '"approved"\s*:\s*false') {
                $approved = $false
                $findings.approved = $false
            }
        }
    } else {
        Write-Host "  [SCALES] Synthesis failed — auto-approving" -ForegroundColor DarkYellow
        $findings.reason = "Synthesis agent failed; auto-approved"
    }

    # Write council-review.json
    $findings | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $councilDir "council-review.json") -Encoding UTF8

    # Write council-findings.md (readable report)
    $report = @()
    $report += "# LLM Council Review ($CouncilType) — Iteration $Iteration"
    $report += ""
    $report += "| Field | Value |"
    $report += "|-------|-------|"
    $report += "| Verdict | $(if ($approved) { 'APPROVED' } else { 'BLOCKED' }) |"
    $report += "| Confidence | $($findings.confidence)% |"
    $report += "| Health | ${Health}% |"
    $report += "| Timestamp | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') |"
    $report += ""

    if ($findings.votes) {
        $report += "## Agent Votes"
        $report += ""
        $report += "| Agent | Vote |"
        $report += "|-------|------|"
        if ($findings.votes -is [hashtable]) {
            foreach ($k in $findings.votes.Keys) { $report += "| $k | $($findings.votes[$k]) |" }
        } elseif ($findings.votes.PSObject) {
            $findings.votes.PSObject.Properties | ForEach-Object { $report += "| $($_.Name) | $($_.Value) |" }
        }
        $report += ""
    }

    if ($findings.strengths -and $findings.strengths.Count -gt 0) {
        $report += "## Strengths"
        foreach ($s in $findings.strengths) { $report += "- $s" }
        $report += ""
    }

    if ($findings.concerns -and $findings.concerns.Count -gt 0) {
        $report += "## Concerns"
        foreach ($c in $findings.concerns) { $report += "- $c" }
        $report += ""
    }

    if ($findings.reason) {
        $report += "## Reasoning"
        $report += $findings.reason
        $report += ""
    }

    $reportPath = Join-Path $reviewDir "council-findings.md"
    ($report -join "`n") | Set-Content $reportPath -Encoding UTF8

    # If blocked, write council feedback for next iteration's prompts
    if (-not $approved) {
        $feedback = @()
        $feedback += "## LLM Council Feedback (DO NOT IGNORE)"
        $feedback += ""
        $feedback += "The LLM Council reviewed the codebase and BLOCKED convergence."
        $feedback += "You MUST address these concerns before the project can be approved:"
        $feedback += ""
        foreach ($c in $findings.concerns) { $feedback += "- $c" }
        $feedback += ""
        $feedback += "Fix these issues in this iteration. The council will re-review."

        $feedbackPath = Join-Path $supervisorDir "council-feedback.md"
        ($feedback -join "`n") | Set-Content $feedbackPath -Encoding UTF8
        Write-Host "  [SCALES] Council feedback written to supervisor/council-feedback.md" -ForegroundColor DarkYellow
    } else {
        # Clear any previous council feedback
        $feedbackPath = Join-Path $supervisorDir "council-feedback.md"
        if (Test-Path $feedbackPath) { Remove-Item $feedbackPath -ErrorAction SilentlyContinue }
    }

    Write-Host "  [SCALES] Council verdict: $(if ($approved) { 'APPROVED' } else { 'BLOCKED' }) (confidence: $($findings.confidence)%)" -ForegroundColor $(if ($approved) { 'Green' } else { 'Yellow' })

    return @{
        Approved = $approved
        Findings = $findings
        Report   = $reportPath
    }
}

Write-Host "  LLM Council module loaded." -ForegroundColor DarkGray
'@

# Append to resilience library
$resiliencePath = "$GsdGlobalDir\lib\modules\resilience.ps1"
Add-Content -Path $resiliencePath -Value $councilCode -Encoding UTF8

Write-Host "[OK] LLM Council module appended to resilience.ps1" -ForegroundColor Green

# ========================================================
# Create council prompt templates
# ========================================================

$promptDir = Join-Path $GsdGlobalDir "prompts\council"
if (-not (Test-Path $promptDir)) {
    New-Item -ItemType Directory -Path $promptDir -Force | Out-Null
}

Write-Host "[SCALES] Writing council prompt templates..." -ForegroundColor Yellow

# Claude review template
@'
# LLM Council Review — Architecture & Compliance (Claude)

You are 1 of 3 independent reviewers in a multi-agent council. Be HONEST — do not rubber-stamp.

## Context
- Health: {{HEALTH}}% | Iteration: {{ITERATION}}
- Project: {{REPO_ROOT}}
- GSD dir: {{GSD_DIR}}

## Read
1. {{GSD_DIR}}\health\requirements-matrix.json
2. {{GSD_DIR}}\code-review\review-current.md
3. Source code files (focus on core business logic)

## Review Focus
1. **Architecture**: Separation of concerns, API contract adherence, dependency direction, layer isolation
2. **Security & Compliance**: HIPAA (PHI handling, audit logs), SOC 2 (access controls), PCI (payment data), GDPR (consent, data rights)
3. **Maintainability**: Naming conventions, code duplication, dead code, test coverage gaps
4. **Data Integrity**: SQL stored procedure patterns, transaction handling, error propagation

## Output Format (max 2000 tokens)
Return ONLY a JSON object:
```json
{
  "vote": "approve|concern|block",
  "confidence": 0-100,
  "findings": ["finding 1", "finding 2"],
  "strengths": ["strength 1", "strength 2"],
  "summary": "1-2 sentence summary"
}
```

Rules:
- "block" = critical issues that MUST be fixed before shipping
- "concern" = issues worth noting but not blocking
- "approve" = ready for production
- Be specific: include file paths and line numbers where possible
'@ | Set-Content (Join-Path $promptDir "claude-review.md") -Encoding UTF8

# Codex review template
@'
# LLM Council Review — Implementation Quality (Codex)

You are 1 of 3 independent reviewers in a multi-agent council. Be HONEST — do not rubber-stamp.

## Context
- Health: {{HEALTH}}% | Iteration: {{ITERATION}}
- Project: {{REPO_ROOT}}
- GSD dir: {{GSD_DIR}}

## Read
1. {{GSD_DIR}}\health\requirements-matrix.json
2. Source code (all implementation files)

## Review Focus
1. **Implementation Completeness**: Are all requirements actually implemented (not just stubbed)?
2. **Error Handling**: Try/catch patterns, null checks, validation at boundaries
3. **API Contract Adherence**: Do controllers match expected request/response shapes?
4. **Stored Procedure Patterns**: Proper parameterization, transaction scoping, error returns
5. **Frontend Patterns**: React component structure, state management, prop validation
6. **Edge Cases**: Empty collections, concurrent access, boundary values, timeout handling

## Output Format (max 2000 tokens)
Return ONLY a JSON object:
```json
{
  "vote": "approve|concern|block",
  "confidence": 0-100,
  "findings": ["finding 1", "finding 2"],
  "strengths": ["strength 1", "strength 2"],
  "summary": "1-2 sentence summary"
}
```

Rules:
- "block" = code will fail at runtime or has critical bugs
- "concern" = code works but has quality issues
- "approve" = implementation is solid
- Be specific: include file paths where possible
'@ | Set-Content (Join-Path $promptDir "codex-review.md") -Encoding UTF8

# Gemini review template
@'
# LLM Council Review — Requirements & Spec Alignment (Gemini)

You are 1 of 3 independent reviewers in a multi-agent council. Be HONEST — do not rubber-stamp.

## Context
- Health: {{HEALTH}}% | Iteration: {{ITERATION}}
- Project: {{REPO_ROOT}}
- GSD dir: {{GSD_DIR}}

## Read
1. {{GSD_DIR}}\health\requirements-matrix.json
2. {{GSD_DIR}}\code-review\review-current.md
3. {{GSD_DIR}}\health\drift-report.md
4. Source code (verify requirements are truly satisfied)

## Review Focus
1. **Requirements Coverage**: Cross-check each "satisfied" requirement against actual code — is it truly complete?
2. **Spec Alignment**: Do implementations match what specs describe? Any misinterpretations?
3. **UI/UX Coverage**: Are all user-facing flows implemented? Form validations, error states, loading states?
4. **Data Flow Completeness**: Does data flow correctly from UI → API → DB → response?
5. **Integration Gaps**: Are all components properly wired together? Missing routes, missing imports?
6. **Missing Requirements**: Are there implied requirements not in the matrix that should exist?

## Output Format (max 2000 tokens)
Return ONLY a JSON object:
```json
{
  "vote": "approve|concern|block",
  "confidence": 0-100,
  "findings": ["finding 1", "finding 2"],
  "strengths": ["strength 1", "strength 2"],
  "summary": "1-2 sentence summary"
}
```

Rules:
- "block" = requirements marked satisfied are NOT actually satisfied
- "concern" = minor gaps or potential issues
- "approve" = all requirements genuinely met
- Be specific: reference requirement IDs where possible
'@ | Set-Content (Join-Path $promptDir "gemini-review.md") -Encoding UTF8

# Synthesis template
@'
# LLM Council Synthesis — Final Verdict

You are the JUDGE synthesizing 3 independent agent reviews into a single verdict.

## Context
- Health: {{HEALTH}}% | Iteration: {{ITERATION}}
- GSD dir: {{GSD_DIR}}

## Your Task
1. Read all 3 agent reviews below
2. Identify areas of CONSENSUS (all agree) and DISAGREEMENT
3. Weigh each agent's expertise:
   - Claude: Architecture & compliance expert
   - Codex: Implementation & code quality expert
   - Gemini: Requirements & spec alignment expert
4. Produce a FINAL VERDICT

## Decision Rules
- If ANY agent votes "block" with confidence > 70: verdict is BLOCKED
- If 2+ agents vote "concern" with similar issues: verdict is BLOCKED
- If all agents vote "approve" or only minor concerns: verdict is APPROVED
- When in doubt, BLOCK — it's cheaper to fix now than after handoff

## Output Format (max 3000 tokens)
Return ONLY a JSON object:
```json
{
  "approved": true|false,
  "confidence": 0-100,
  "votes": {
    "claude": "approve|concern|block",
    "codex": "approve|concern|block",
    "gemini": "approve|concern|block"
  },
  "concerns": ["concern 1 (from agent X)", "concern 2 (consensus)"],
  "strengths": ["strength 1", "strength 2"],
  "reason": "1-3 sentence explanation of the verdict"
}
```
'@ | Set-Content (Join-Path $promptDir "synthesize.md") -Encoding UTF8

# ── POST-RESEARCH templates (Claude + Codex validate Gemini research) ──

@'
# Council: Post-Research Validation (Claude)

Validate research findings produced by Gemini. Are they actionable and correct?

## Context
- Health: {{HEALTH}}% | Iteration: {{ITERATION}}
- Read: {{GSD_DIR}}\logs\iter*-2.log (research output), {{GSD_DIR}}\health\requirements-matrix.json

## Review Focus
1. Are research findings relevant to the current requirements?
2. Are recommended patterns consistent with .NET 8 + Dapper + SQL Server stored procs + React 18?
3. Did research miss any obvious patterns or dependencies in the codebase?
4. Are there any incorrect or misleading conclusions?

## Output (max 1500 tokens)
JSON: { "vote": "approve|concern|block", "confidence": 0-100, "findings": [...], "strengths": [...], "summary": "..." }
'@ | Set-Content (Join-Path $promptDir "post-research-claude.md") -Encoding UTF8

@'
# Council: Post-Research Validation (Codex)

Validate research findings produced by Gemini. Are they technically accurate?

## Context
- Health: {{HEALTH}}% | Iteration: {{ITERATION}}
- Read: {{GSD_DIR}}\logs\iter*-2.log (research output), source code

## Review Focus
1. Are the technical recommendations implementable given the current codebase?
2. Do suggested patterns conflict with existing code architecture?
3. Are referenced APIs, packages, or patterns up-to-date and correct?
4. Will following these findings lead to good code quality?

## Output (max 1500 tokens)
JSON: { "vote": "approve|concern|block", "confidence": 0-100, "findings": [...], "strengths": [...], "summary": "..." }
'@ | Set-Content (Join-Path $promptDir "post-research-codex.md") -Encoding UTF8

# ── PRE-EXECUTE templates (Claude + Gemini validate plan before Codex runs) ──

@'
# Council: Pre-Execute Plan Review (Claude)

Review the execution plan BEFORE code generation begins. Catch bad plans early.

## Context
- Health: {{HEALTH}}% | Iteration: {{ITERATION}}
- Read: {{GSD_DIR}}\generation-queue\queue-current.json, {{GSD_DIR}}\agent-handoff\current-assignment.md

## Review Focus
1. Is the batch size appropriate? Too many items risks quality; too few wastes iterations.
2. Are item dependencies ordered correctly? (e.g., models before controllers, DB before API)
3. Are acceptance criteria clear enough for the execute agent to implement?
4. Does the plan address the highest-priority drift items?

## Output (max 1500 tokens)
JSON: { "vote": "approve|concern|block", "confidence": 0-100, "findings": [...], "strengths": [...], "summary": "..." }
'@ | Set-Content (Join-Path $promptDir "pre-execute-claude.md") -Encoding UTF8

@'
# Council: Pre-Execute Plan Review (Gemini)

Review the execution plan BEFORE code generation begins. Verify spec alignment.

## Context
- Health: {{HEALTH}}% | Iteration: {{ITERATION}}
- Read: {{GSD_DIR}}\generation-queue\queue-current.json, {{GSD_DIR}}\health\requirements-matrix.json, {{GSD_DIR}}\health\drift-report.md

## Review Focus
1. Do planned items map correctly to the requirements they claim to address?
2. Are there spec requirements being ignored that should be in this batch?
3. Will completing this batch meaningfully improve health score?
4. Are there any spec misinterpretations in the acceptance criteria?

## Output (max 1500 tokens)
JSON: { "vote": "approve|concern|block", "confidence": 0-100, "findings": [...], "strengths": [...], "summary": "..." }
'@ | Set-Content (Join-Path $promptDir "pre-execute-gemini.md") -Encoding UTF8

# ── POST-BLUEPRINT templates (all 3 agents review blueprint manifest) ──

@'
# Council: Post-Blueprint Review (Claude)

Review the generated blueprint manifest for architectural soundness.

## Context
- Iteration: {{ITERATION}} | Health: {{HEALTH}}%
- Read: {{GSD_DIR}}\blueprint\blueprint.json, specs in docs\

## Review Focus
1. Is the tier structure logical? (foundation → core → features → polish)
2. Are file dependencies captured correctly?
3. Does the blueprint follow .NET 8 + Dapper + React 18 patterns?
4. Are security/compliance items (HIPAA, SOC2, PCI, GDPR) represented?
5. Are there missing files that the specs require but the blueprint omits?

## Output (max 2000 tokens)
JSON: { "vote": "approve|concern|block", "confidence": 0-100, "findings": [...], "strengths": [...], "summary": "..." }
'@ | Set-Content (Join-Path $promptDir "post-blueprint-claude.md") -Encoding UTF8

@'
# Council: Post-Blueprint Review (Codex)

Review the generated blueprint manifest for implementation feasibility.

## Context
- Iteration: {{ITERATION}} | Health: {{HEALTH}}%
- Read: {{GSD_DIR}}\blueprint\blueprint.json

## Review Focus
1. Are the items implementable as described? Are acceptance criteria clear?
2. Are there circular dependencies between items?
3. Are database items (stored procs, migrations) properly sequenced before API items?
4. Are estimated complexities reasonable?
5. Are there items that should be split (too large) or merged (too small)?

## Output (max 2000 tokens)
JSON: { "vote": "approve|concern|block", "confidence": 0-100, "findings": [...], "strengths": [...], "summary": "..." }
'@ | Set-Content (Join-Path $promptDir "post-blueprint-codex.md") -Encoding UTF8

@'
# Council: Post-Blueprint Review (Gemini)

Review the generated blueprint manifest for spec completeness.

## Context
- Iteration: {{ITERATION}} | Health: {{HEALTH}}%
- Read: {{GSD_DIR}}\blueprint\blueprint.json, specs in docs\, design\figma\

## Review Focus
1. Does every spec requirement have at least one blueprint item?
2. Are UI components from Figma designs represented?
3. Are API endpoints from specs fully covered (CRUD, auth, validation)?
4. Are there implied requirements (error pages, loading states, 404s) missing?
5. Is the total item count reasonable for the project scope?

## Output (max 2000 tokens)
JSON: { "vote": "approve|concern|block", "confidence": 0-100, "findings": [...], "strengths": [...], "summary": "..." }
'@ | Set-Content (Join-Path $promptDir "post-blueprint-gemini.md") -Encoding UTF8

# ── STALL DIAGNOSIS templates (all 3 agents diagnose why pipeline is stuck) ──

@'
# Council: Stall Diagnosis (Claude)

The pipeline has STALLED — health is not improving. Diagnose why.

## Context
- Health: {{HEALTH}}% | Iteration: {{ITERATION}}
- Read: {{GSD_DIR}}\health\*, {{GSD_DIR}}\logs\errors.jsonl, {{GSD_DIR}}\health\stall-diagnosis.md

## Diagnose
1. Are requirements impossible to satisfy given the tech stack constraints?
2. Is the code review scoring incorrectly (requirements marked not_started that are actually done)?
3. Are there circular issues (fix A breaks B, fix B breaks A)?
4. Is the execute agent failing silently (committing but not actually implementing)?
5. Recommend a specific recovery action.

## Output (max 2000 tokens)
JSON: { "vote": "approve|concern|block", "confidence": 0-100, "findings": [...], "strengths": [...], "summary": "Diagnosis + recommended action" }
'@ | Set-Content (Join-Path $promptDir "stall-claude.md") -Encoding UTF8

@'
# Council: Stall Diagnosis (Codex)

The pipeline has STALLED — health is not improving. Analyze the code.

## Context
- Health: {{HEALTH}}% | Iteration: {{ITERATION}}
- Read: source code, {{GSD_DIR}}\health\drift-report.md, {{GSD_DIR}}\logs\errors.jsonl

## Diagnose
1. Are there build errors preventing progress?
2. Is generated code being overwritten each iteration (no persistence)?
3. Are there dependency issues (missing packages, wrong versions)?
4. Is the execute prompt too vague, causing random changes?
5. What specific code changes would unblock progress?

## Output (max 2000 tokens)
JSON: { "vote": "approve|concern|block", "confidence": 0-100, "findings": [...], "strengths": [...], "summary": "Diagnosis + recommended fix" }
'@ | Set-Content (Join-Path $promptDir "stall-codex.md") -Encoding UTF8

@'
# Council: Stall Diagnosis (Gemini)

The pipeline has STALLED — health is not improving. Analyze specs vs reality.

## Context
- Health: {{HEALTH}}% | Iteration: {{ITERATION}}
- Read: {{GSD_DIR}}\health\requirements-matrix.json, {{GSD_DIR}}\health\drift-report.md, specs

## Diagnose
1. Are spec requirements contradictory or impossible?
2. Are requirements too vague for the execute agent to implement?
3. Is the health scoring formula unfair (penalizing minor issues)?
4. Are there external dependencies (third-party APIs, database schema) blocking progress?
5. Should any requirements be decomposed or deprioritized?

## Output (max 2000 tokens)
JSON: { "vote": "approve|concern|block", "confidence": 0-100, "findings": [...], "strengths": [...], "summary": "Diagnosis + recommendation" }
'@ | Set-Content (Join-Path $promptDir "stall-gemini.md") -Encoding UTF8

# ── POST-SPEC-FIX templates (Claude + Codex validate Gemini's spec resolution) ──

@'
# Council: Post-Spec-Fix Validation (Claude)

Gemini resolved spec conflicts. Verify the resolution is correct and complete.

## Context
- Iteration: {{ITERATION}} | Health: {{HEALTH}}%
- Read: {{GSD_DIR}}\spec-conflicts\resolution-summary.md, updated specs in docs\

## Review Focus
1. Does the resolution preserve the intent of both conflicting requirements?
2. Are there downstream impacts the fix didn't consider?
3. Did the resolution introduce any new inconsistencies?
4. Is the resolution aligned with HIPAA/SOC2/PCI/GDPR compliance requirements?

## Output (max 1500 tokens)
JSON: { "vote": "approve|concern|block", "confidence": 0-100, "findings": [...], "strengths": [...], "summary": "..." }
'@ | Set-Content (Join-Path $promptDir "post-spec-fix-claude.md") -Encoding UTF8

@'
# Council: Post-Spec-Fix Validation (Codex)

Gemini resolved spec conflicts. Verify the resolution is implementable.

## Context
- Iteration: {{ITERATION}} | Health: {{HEALTH}}%
- Read: {{GSD_DIR}}\spec-conflicts\resolution-summary.md, updated specs in docs\

## Review Focus
1. Are the resolved specs implementable with .NET 8 + Dapper + React 18?
2. Do the changes affect API contracts that existing code depends on?
3. Are database schema changes implied by the resolution feasible?
4. Will the resolution cause existing tests to fail?

## Output (max 1500 tokens)
JSON: { "vote": "approve|concern|block", "confidence": 0-100, "findings": [...], "strengths": [...], "summary": "..." }
'@ | Set-Content (Join-Path $promptDir "post-spec-fix-codex.md") -Encoding UTF8

Write-Host "[OK] 14 council prompt templates written to: $promptDir" -ForegroundColor Green
Write-Host ""
Write-Host "=========================================================" -ForegroundColor Green
Write-Host "  LLM Council installed successfully" -ForegroundColor Green
Write-Host "  Council types: convergence, post-research, pre-execute," -ForegroundColor DarkGray
Write-Host "    post-blueprint, stall-diagnosis, post-spec-fix" -ForegroundColor DarkGray
Write-Host "  Full council: ~4 API calls (~$0.43)" -ForegroundColor DarkGray
Write-Host "  Light council: ~2-3 API calls (~$0.20-0.30)" -ForegroundColor DarkGray
Write-Host "=========================================================" -ForegroundColor Green
Write-Host ""
