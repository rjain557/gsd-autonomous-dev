<#
.SYNOPSIS
    GSD Partitioned Code Review - 3-way parallel review with agent rotation.
    Run AFTER patch-gsd-runtime-smoke-test.ps1.

.DESCRIPTION
    Replaces single-agent code review with a 3-partition parallel review system.
    Each iteration, the codebase is split into three partitions (A, B, C) and
    reviewed simultaneously by Claude, Codex, and Gemini. Agent assignments
    rotate each iteration so that over 3 turns, every agent has reviewed
    every partition of the code.

    Partition strategy:
    - Requirements from the matrix are split into 3 roughly equal groups
    - Each group includes corresponding source files, specs, and Figma artifacts
    - Agents review their partition against BOTH spec documents AND Figma deliverables

    Rotation matrix (repeats every 3 iterations):
      Iter 1: A=Claude  B=Gemini  C=Codex
      Iter 2: A=Gemini  B=Codex   C=Claude
      Iter 3: A=Codex   B=Claude  C=Gemini

    This ensures:
    - Full coverage: every requirement reviewed by every LLM within 3 iterations
    - Diversity: different agents catch different types of issues
    - Parallelism: 3x faster than sequential single-agent review
    - Spec+Figma: agents validate code against deliverables, not just compilation

    Adds:
    1. Invoke-PartitionedCodeReview function to resilience.ps1
    2. Split-RequirementsIntoPartitions helper function
    3. Merge-PartitionedReviews merger function
    4. 3 prompt templates: code-review-partition-A/B/C.md (shared)
    5. Patches convergence pipeline to use partitioned review
    6. Config: partitioned_code_review block in global-config.json

.INSTALL_ORDER
    1-32. (existing scripts)
    33. patch-gsd-partitioned-code-review.ps1  <- this file

.NOTES
    Created to ensure generated code is thoroughly reviewed against spec and
    Figma deliverables before reaching 100%. The rotation ensures no blind
    spots from single-agent bias.
#>

param([string]$UserHome = $env:USERPROFILE)
$ErrorActionPreference = "Stop"

$GsdGlobalDir = Join-Path $UserHome ".gsd-global"

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  GSD Partitioned Code Review" -ForegroundColor Cyan
Write-Host "  3-way parallel review with agent rotation" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

# ── 1. Add partitioned_code_review config ──

$configPath = Join-Path $GsdGlobalDir "config\global-config.json"
if (Test-Path $configPath) {
    $config = Get-Content $configPath -Raw | ConvertFrom-Json

    if (-not $config.partitioned_code_review) {
        $config | Add-Member -NotePropertyName "partitioned_code_review" -NotePropertyValue ([PSCustomObject]@{
            enabled              = $true
            partition_count      = 3
            agents               = @("claude", "codex", "gemini")
            rotation_enabled     = $true
            merge_strategy       = "strict_union"
            timeout_seconds      = 600
            validate_against_spec = $true
            validate_against_figma = $true
            fallback_to_single   = $true
            cooldown_between_agents = 5
        })
        $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath -Encoding UTF8
        Write-Host "  [OK] Added partitioned_code_review config" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] partitioned_code_review config already exists" -ForegroundColor DarkGray
    }
}

# ── 2. Create shared partition prompt templates ──

$sharedDir = Join-Path $GsdGlobalDir "prompts\shared"
if (-not (Test-Path $sharedDir)) {
    New-Item -Path $sharedDir -ItemType Directory -Force | Out-Null
}

# Template A: Implementation & Architecture Focus
$templateA = @'
# Code Review - Partition A: Implementation & Architecture

You are reviewing **Partition A** of the codebase. Another agent is reviewing partitions B and C simultaneously.

## Your Assigned Requirements
{{PARTITION_REQUIREMENTS}}

## Your Assigned Files
{{PARTITION_FILES}}

## Review Against Deliverables

### Spec Validation
Read the following spec documents and validate that each assigned requirement is correctly implemented:
{{SPEC_PATHS}}

For each requirement, check:
1. Does the implementation match the spec's acceptance criteria?
2. Are all API endpoints, parameters, and response shapes correct per spec?
3. Are stored procedures, table schemas, and relationships correct?
4. Are security requirements (auth, roles, HIPAA/SOC2/PCI/GDPR) met?

### Figma Validation
Read the following Figma analysis files and validate UI implementation:
{{FIGMA_PATHS}}

For each UI requirement, check:
1. Do components match the Figma design structure?
2. Are all form fields, buttons, and interactions present?
3. Are error states, loading states, and empty states handled?
4. Do layout, spacing, and component hierarchy match the design?

## Implementation Quality
1. **DI Lifetimes**: No Scoped services injected into Singletons
2. **FK Seed Order**: Parent tables INSERTed before child tables
3. **Error Handling**: Controllers return proper HTTP status codes (not generic 500)
4. **API Contracts**: Routes, methods, and shapes match spec

## Output Format

### 1. Update requirements-matrix.json
For EACH requirement in your partition, update its status:
- `satisfied`: Implementation matches spec AND Figma (where applicable)
- `partial`: Partially implemented or deviates from spec/Figma
- `not_started`: No implementation found

### 2. Write partition review to .gsd/code-review/partition-A-review.md
Max 80 lines. Format:
```
## Partition A Review (Iter {{ITERATION}})
Agent: {{AGENT_NAME}}

### Spec Compliance
| Req ID | Status | Spec Match | Figma Match | Issue |
|--------|--------|------------|-------------|-------|
| REQ-xx | satisfied | yes | yes | - |
| REQ-yy | partial | no | yes | Missing auth on endpoint |

### Critical Issues (blocking)
- file.cs:42 - Missing [Authorize] attribute on AdminController
- seed.sql:15 - INSERT into MyGPTs before Users table (FK violation)

### Warnings (non-blocking)
- Component.tsx:88 - Missing loading state from Figma design

### DI & Runtime Issues
- Scoped service IMyService injected into Singleton middleware
```

### 3. Write drift items to .gsd/code-review/partition-A-drift.md
Max 30 lines. Bullet list of gaps between spec/Figma and actual code.

## Token Budget: 3000 tokens max. Tables and bullets only. No prose.
'@

# Template B: Data Flow & Integration Focus
$templateB = @'
# Code Review - Partition B: Data Flow & Integration

You are reviewing **Partition B** of the codebase. Another agent is reviewing partitions A and C simultaneously.

## Your Assigned Requirements
{{PARTITION_REQUIREMENTS}}

## Your Assigned Files
{{PARTITION_FILES}}

## Review Against Deliverables

### Spec Validation
Read the following spec documents and validate that each assigned requirement is correctly implemented:
{{SPEC_PATHS}}

For each requirement, check:
1. Does the full data flow work: UI -> API -> Stored Proc -> Table -> Response?
2. Are all API routes registered and reachable?
3. Do request/response DTOs match the documented contracts?
4. Are database migrations and seed data complete and correctly ordered?

### Figma Validation
Read the following Figma analysis files and validate UI implementation:
{{FIGMA_PATHS}}

For each UI requirement, check:
1. Do data-bound components display the correct fields?
2. Are form submissions wired to the correct API endpoints?
3. Are validation rules from Figma annotations implemented?
4. Do navigation flows match the Figma flow diagrams?

## Integration Quality
1. **End-to-End Chains**: Trace from React component -> API call -> Controller -> SP -> Table
2. **Missing Wiring**: Components that call APIs that don't exist, or SPs with no controller
3. **Seed Data Integrity**: FK references point to existing parent records
4. **Connection Strings**: appsettings.json has correct DB references

## Output Format

### 1. Update requirements-matrix.json
For EACH requirement in your partition, update its status.

### 2. Write partition review to .gsd/code-review/partition-B-review.md
Max 80 lines. Same table format as Partition A.

### 3. Write drift items to .gsd/code-review/partition-B-drift.md
Max 30 lines. Bullet list of integration gaps.

## Token Budget: 3000 tokens max. Tables and bullets only. No prose.
'@

# Template C: Security, Compliance & UX Focus
$templateC = @'
# Code Review - Partition C: Security, Compliance & UX

You are reviewing **Partition C** of the codebase. Another agent is reviewing partitions A and B simultaneously.

## Your Assigned Requirements
{{PARTITION_REQUIREMENTS}}

## Your Assigned Files
{{PARTITION_FILES}}

## Review Against Deliverables

### Spec Validation
Read the following spec documents and validate compliance requirements:
{{SPEC_PATHS}}

For each requirement, check:
1. Are all security controls from the spec implemented?
2. Are HIPAA/SOC2/PCI/GDPR requirements addressed?
3. Are audit logging, encryption, and access controls present?
4. Are input validation and output encoding correct?

### Figma Validation
Read the following Figma analysis files and validate UX:
{{FIGMA_PATHS}}

For each UI requirement, check:
1. Are all accessibility attributes present (aria-*, alt text)?
2. Do error messages match Figma copy?
3. Are responsive breakpoints implemented?
4. Are all Figma-specified interactions (hover, focus, disabled) present?

## Security & Compliance Checks
1. **OWASP Top 10**: SQL injection, XSS, CSRF, auth bypass
2. **[Authorize]**: All controllers except health/login require auth
3. **Secrets**: No hardcoded API keys, connection strings, or passwords
4. **PHI/PII**: Encrypted at rest, audit logged, consent tracked
5. **Input Validation**: All user inputs validated server-side

## Output Format

### 1. Update requirements-matrix.json
For EACH requirement in your partition, update its status.

### 2. Write partition review to .gsd/code-review/partition-C-review.md
Max 80 lines. Same table format as Partition A.

### 3. Write drift items to .gsd/code-review/partition-C-drift.md
Max 30 lines. Bullet list of security/compliance/UX gaps.

## Token Budget: 3000 tokens max. Tables and bullets only. No prose.
'@

Set-Content -Path (Join-Path $sharedDir "code-review-partition-A.md") -Value $templateA -Encoding UTF8
Set-Content -Path (Join-Path $sharedDir "code-review-partition-B.md") -Value $templateB -Encoding UTF8
Set-Content -Path (Join-Path $sharedDir "code-review-partition-C.md") -Value $templateC -Encoding UTF8
Write-Host "  [OK] Created 3 partition prompt templates" -ForegroundColor Green

# ── 3. Add partitioned code review functions to resilience.ps1 ──

$resilienceFile = Join-Path $GsdGlobalDir "lib\modules\resilience.ps1"
if (Test-Path $resilienceFile) {
    $existing = Get-Content $resilienceFile -Raw

    $partitionCode = @'

# ===============================================================
# GSD PARTITIONED CODE REVIEW MODULES - appended to resilience.ps1
# ===============================================================

# Agent rotation matrix: maps (iteration % 3) to agent assignments for partitions A, B, C
$script:PARTITION_ROTATION = @(
    @{ A = "claude";  B = "gemini"; C = "codex"  }  # Iter 1, 4, 7, ...
    @{ A = "gemini";  B = "codex";  C = "claude" }  # Iter 2, 5, 8, ...
    @{ A = "codex";   B = "claude"; C = "gemini" }  # Iter 3, 6, 9, ...
)


function Split-RequirementsIntoPartitions {
    <#
    .SYNOPSIS
        Splits requirements matrix into 3 roughly equal partitions.
        Each partition includes the requirement IDs and their associated files.
    #>
    param(
        [string]$GsdDir,
        [int]$PartitionCount = 3
    )

    $matrixPath = Join-Path $GsdDir "health\requirements-matrix.json"
    if (-not (Test-Path $matrixPath)) {
        Write-Host "  [WARN] No requirements-matrix.json found" -ForegroundColor Yellow
        return $null
    }

    try {
        $matrix = Get-Content $matrixPath -Raw | ConvertFrom-Json
        $reqs = @($matrix.requirements)
    } catch {
        Write-Host "  [WARN] Failed to parse requirements-matrix.json" -ForegroundColor Yellow
        return $null
    }

    if ($reqs.Count -lt $PartitionCount) {
        Write-Host "  [WARN] Only $($reqs.Count) requirements -- too few to partition" -ForegroundColor Yellow
        return $null
    }

    # Sort requirements: not_started first, then partial, then satisfied
    # This ensures each partition gets a mix of statuses
    $sorted = $reqs | Sort-Object @{
        Expression = {
            switch ($_.status) {
                "not_started" { 0 }
                "partial"     { 1 }
                "satisfied"   { 2 }
                default       { 3 }
            }
        }
    }

    # Round-robin distribute to ensure even split
    $partitions = @()
    for ($i = 0; $i -lt $PartitionCount; $i++) {
        $partitions += ,@()
    }

    $idx = 0
    foreach ($req in $sorted) {
        $partitions[$idx % $PartitionCount] += $req
        $idx++
    }

    # Build partition objects with file lists
    $labels = @("A", "B", "C")
    $result = @()
    for ($i = 0; $i -lt $PartitionCount; $i++) {
        $reqIds = @($partitions[$i] | ForEach-Object { $_.id })
        $files = @($partitions[$i] | ForEach-Object {
            if ($_.satisfied_by) { $_.satisfied_by }
            elseif ($_.files) { $_.files }
            elseif ($_.target_files) { $_.target_files }
        } | Where-Object { $_ } | Select-Object -Unique)

        # Format requirements as table for prompt injection
        $reqTable = "| ID | Description | Current Status |`n|-----|-------------|----------------|"
        foreach ($r in $partitions[$i]) {
            $desc = if ($r.description -and $r.description.Length -gt 60) { $r.description.Substring(0, 60) + "..." } else { $r.description }
            $reqTable += "`n| $($r.id) | $desc | $($r.status) |"
        }

        $result += @{
            Label         = $labels[$i]
            Requirements  = $partitions[$i]
            RequirementIds = $reqIds
            Files         = $files
            ReqTable      = $reqTable
            Count         = $partitions[$i].Count
        }
    }

    return $result
}


function Get-SpecAndFigmaPaths {
    <#
    .SYNOPSIS
        Discovers spec documents and Figma analysis files in the project.
    #>
    param(
        [string]$RepoRoot,
        [string]$GsdDir
    )

    $specPaths = @()
    $figmaPaths = @()

    # Spec files: look in .gsd/specs/, design/, docs/
    $specDirs = @(
        (Join-Path $GsdDir "specs"),
        (Join-Path $RepoRoot "design"),
        (Join-Path $RepoRoot "docs"),
        (Join-Path $RepoRoot "_analysis")
    )
    foreach ($dir in $specDirs) {
        if (Test-Path $dir) {
            $specFiles = Get-ChildItem -Path $dir -Filter "*.md" -Recurse -Depth 3 -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch "(figma|screenshot|visual)" }
            foreach ($sf in $specFiles) {
                $relPath = $sf.FullName.Replace("$RepoRoot\", "").Replace("$GsdDir\", ".gsd\")
                $specPaths += $relPath
            }
        }
    }

    # Figma analysis files: look in design/*/_analysis/, .gsd/specs/figma*
    $figmaDirs = @(
        (Join-Path $RepoRoot "design"),
        (Join-Path $GsdDir "specs")
    )
    foreach ($dir in $figmaDirs) {
        if (Test-Path $dir) {
            $figmaFiles = Get-ChildItem -Path $dir -Filter "*.md" -Recurse -Depth 4 -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match "(figma|_analysis|storyboard|visual|screenshot)" }
            foreach ($ff in $figmaFiles) {
                $relPath = $ff.FullName.Replace("$RepoRoot\", "").Replace("$GsdDir\", ".gsd\")
                $figmaPaths += $relPath
            }
        }
    }

    # Also look for Figma mapping in .gsd
    $figmaMapping = Join-Path $GsdDir "specs\figma-mapping.md"
    if ((Test-Path $figmaMapping) -and ($figmaPaths -notcontains ".gsd\specs\figma-mapping.md")) {
        $figmaPaths += ".gsd\specs\figma-mapping.md"
    }

    return @{
        SpecPaths  = $specPaths | Select-Object -Unique
        FigmaPaths = $figmaPaths | Select-Object -Unique
    }
}


function Invoke-PartitionedCodeReview {
    <#
    .SYNOPSIS
        Runs 3-partition parallel code review with agent rotation.
        Replaces single-agent code review when enabled.
    .RETURNS
        Hashtable with merged health score and combined review findings.
    #>
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [string]$GlobalDir,
        [int]$Iteration,
        [double]$Health,
        [int]$CurrentBatchSize = 8,
        [string]$InterfaceContext = "",
        [switch]$DryRun
    )

    $result = @{
        Success    = $true
        Health     = $Health
        Error      = ""
        AgentMap   = @{}
        Partitions = @()
    }

    # Load config
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    $pcConfig = $null
    if (Test-Path $configPath) {
        try {
            $pcConfig = (Get-Content $configPath -Raw | ConvertFrom-Json).partitioned_code_review
        } catch {}
    }

    if (-not $pcConfig -or -not $pcConfig.enabled) {
        $result.Success = $false
        $result.Error = "Partitioned code review disabled"
        return $result
    }

    $agents = @($pcConfig.agents)
    if ($agents.Count -lt 3) { $agents = @("claude", "codex", "gemini") }
    $cooldown = if ($pcConfig.cooldown_between_agents) { [int]$pcConfig.cooldown_between_agents } else { 5 }

    # 1. Split requirements into partitions
    Write-Host "  [PARTITION] Splitting requirements into 3 partitions..." -ForegroundColor Cyan
    $partitions = Split-RequirementsIntoPartitions -GsdDir $GsdDir -PartitionCount 3

    if (-not $partitions -or $partitions.Count -lt 3) {
        Write-Host "  [PARTITION] Cannot partition (too few requirements). Falling back to single review." -ForegroundColor Yellow
        $result.Success = $false
        $result.Error = "Too few requirements to partition"
        return $result
    }

    foreach ($p in $partitions) {
        Write-Host "    Partition $($p.Label): $($p.Count) requirements, $($p.Files.Count) files" -ForegroundColor DarkGray
    }

    # 2. Determine agent rotation for this iteration
    $rotationIdx = ($Iteration - 1) % 3
    $rotation = $script:PARTITION_ROTATION[$rotationIdx]

    Write-Host "  [PARTITION] Rotation (iter $Iteration -> slot $rotationIdx):" -ForegroundColor Cyan
    Write-Host "    A=$($rotation.A)  B=$($rotation.B)  C=$($rotation.C)" -ForegroundColor White
    $result.AgentMap = $rotation

    # 3. Discover spec and Figma paths
    $deliverables = Get-SpecAndFigmaPaths -RepoRoot $RepoRoot -GsdDir $GsdDir
    $specList = if ($deliverables.SpecPaths.Count -gt 0) {
        ($deliverables.SpecPaths | ForEach-Object { "- Read: ``$_``" }) -join "`n"
    } else { "- No spec documents found. Review code against requirements descriptions." }

    $figmaList = if ($deliverables.FigmaPaths.Count -gt 0) {
        ($deliverables.FigmaPaths | ForEach-Object { "- Read: ``$_``" }) -join "`n"
    } else { "- No Figma analysis files found. Skip Figma validation." }

    # 4. Build prompts for each partition
    $templateDir = Join-Path $GlobalDir "prompts\shared"
    $labels = @("A", "B", "C")
    $agentKeys = @("A", "B", "C")
    $prompts = @{}
    $logFiles = @{}

    foreach ($label in $labels) {
        $partition = $partitions | Where-Object { $_.Label -eq $label }
        $agent = $rotation[$label]
        $templateFile = Join-Path $templateDir "code-review-partition-$label.md"

        if (-not (Test-Path $templateFile)) {
            Write-Host "  [WARN] Template not found: code-review-partition-$label.md" -ForegroundColor Yellow
            continue
        }

        $template = Get-Content $templateFile -Raw

        # Resolve placeholders
        $fileList = if ($partition.Files.Count -gt 0) {
            ($partition.Files | ForEach-Object { "- ``$_``" }) -join "`n"
        } else { "- (No specific files mapped. Scan requirements descriptions for target files.)" }

        $prompt = $template.Replace("{{PARTITION_REQUIREMENTS}}", $partition.ReqTable)
        $prompt = $prompt.Replace("{{PARTITION_FILES}}", $fileList)
        $prompt = $prompt.Replace("{{SPEC_PATHS}}", $specList)
        $prompt = $prompt.Replace("{{FIGMA_PATHS}}", $figmaList)
        $prompt = $prompt.Replace("{{ITERATION}}", "$Iteration")
        $prompt = $prompt.Replace("{{AGENT_NAME}}", $agent)
        $prompt = $prompt.Replace("{{GSD_DIR}}", $GsdDir)
        $prompt = $prompt.Replace("{{REPO_ROOT}}", $RepoRoot)
        $prompt = $prompt.Replace("{{BATCH_SIZE}}", "$CurrentBatchSize")

        # Append interface context if available
        if ($InterfaceContext) {
            $prompt += "`n`n## Interface Context`n$InterfaceContext"
        }

        # Append file map
        $fileTreePath = Join-Path $GsdDir "file-map-tree.md"
        if (Test-Path $fileTreePath) {
            $prompt += "`n`n## Repository File Map`nRead the tree file at: $fileTreePath"
        }

        # Append supervisor context
        $errorCtxPath = Join-Path $GsdDir "supervisor\error-context.md"
        $hintPath = Join-Path $GsdDir "supervisor\prompt-hints.md"
        if (Test-Path $errorCtxPath) { $prompt += "`n`n## Previous Iteration Errors`n" + (Get-Content $errorCtxPath -Raw) }
        if (Test-Path $hintPath) { $prompt += "`n`n## Supervisor Instructions`n" + (Get-Content $hintPath -Raw) }

        # Council feedback
        $councilFeedbackPath = Join-Path $GsdDir "supervisor\council-feedback.md"
        if (Test-Path $councilFeedbackPath) { $prompt += "`n`n" + (Get-Content $councilFeedbackPath -Raw) }

        $prompts[$label] = @{ Agent = $agent; Prompt = $prompt }
        $logFiles[$label] = Join-Path $GsdDir "logs\iter${Iteration}-1-partition-$label.log"
    }

    if ($DryRun) {
        Write-Host "  [DRY RUN] Would launch 3 parallel reviews" -ForegroundColor DarkGray
        return $result
    }

    # 5. Launch all 3 agents in parallel
    Write-Host "  [PARTITION] Launching 3 parallel reviews..." -ForegroundColor Cyan

    $jobs = @{}
    foreach ($label in $labels) {
        $entry = $prompts[$label]
        $agent = $entry.Agent
        $prompt = $entry.Prompt
        $logFile = $logFiles[$label]

        Write-Host "    $($agent.ToUpper()) -> Partition $label ($($partitions | Where-Object { $_.Label -eq $label } | ForEach-Object { $_.Count }) reqs)" -ForegroundColor Magenta

        # Determine allowed tools per agent type
        $allowedTools = switch ($agent) {
            "claude" { "Read,Write,Bash" }
            "codex"  { $null }  # codex manages its own tools
            "gemini" { $null }  # gemini manages its own tools
            default  { "Read,Write,Bash" }
        }

        # Use PowerShell jobs for parallel execution
        $jobParams = @{
            ScriptBlock = {
                param($GlobalDir, $Agent, $Prompt, $Phase, $LogFile, $BatchSize, $GsdDir, $AllowedTools, $GeminiMode)
                . "$GlobalDir\lib\modules\resilience.ps1"
                $invokeParams = @{
                    Agent = $Agent
                    Prompt = $Prompt
                    Phase = $Phase
                    LogFile = $LogFile
                    CurrentBatchSize = $BatchSize
                    GsdDir = $GsdDir
                }
                if ($AllowedTools) { $invokeParams["AllowedTools"] = $AllowedTools }
                if ($GeminiMode) { $invokeParams["GeminiMode"] = $GeminiMode }
                Invoke-WithRetry @invokeParams
            }
            ArgumentList = @(
                $GlobalDir,
                $agent,
                $prompt,
                "code-review",
                $logFile,
                $CurrentBatchSize,
                $GsdDir,
                $allowedTools,
                $(if ($agent -eq "gemini") { "--approval-mode plan" } else { $null })
            )
        }

        $jobs[$label] = Start-Job @jobParams

        # Small cooldown between launches to avoid burst
        if ($cooldown -gt 0) { Start-Sleep -Seconds $cooldown }
    }

    # 6. Wait for all jobs to complete
    $timeout = if ($pcConfig.timeout_seconds) { [int]$pcConfig.timeout_seconds } else { 600 }
    Write-Host "  [PARTITION] Waiting for all 3 reviews (timeout: ${timeout}s)..." -ForegroundColor Cyan

    $completedJobs = @{}
    $failedPartitions = @()

    foreach ($label in $labels) {
        $job = $jobs[$label]
        $agent = $prompts[$label].Agent

        try {
            $jobResult = $job | Wait-Job -Timeout $timeout | Receive-Job -ErrorAction SilentlyContinue
            if ($job.State -eq "Completed") {
                $completedJobs[$label] = $jobResult
                Write-Host "    [PASS] Partition $label ($agent) completed" -ForegroundColor Green
            } else {
                $failedPartitions += $label
                Write-Host "    [FAIL] Partition $label ($agent) timed out or failed" -ForegroundColor Red
            }
        } catch {
            $failedPartitions += $label
            Write-Host "    [FAIL] Partition $label ($agent): $($_.Exception.Message)" -ForegroundColor Red
        } finally {
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        }
    }

    # 7. Merge partition results
    Write-Host "  [PARTITION] Merging results from $($completedJobs.Count)/3 partitions..." -ForegroundColor Cyan

    $mergeResult = Merge-PartitionedReviews -GsdDir $GsdDir -Partitions $partitions `
        -CompletedLabels @($completedJobs.Keys) -FailedLabels $failedPartitions `
        -Rotation $rotation -Iteration $Iteration

    $result.Health = $mergeResult.Health
    $result.Partitions = $partitions

    if ($failedPartitions.Count -gt 0) {
        $result.Error = "Partitions failed: $($failedPartitions -join ', ')"
        if ($failedPartitions.Count -ge 3) {
            $result.Success = $false
        }
    }

    # 8. Save rotation history
    $rotHistoryPath = Join-Path $GsdDir "code-review\rotation-history.jsonl"
    $rotEntry = @{
        iteration = $Iteration
        rotation_slot = $rotationIdx
        agent_map = $rotation
        partitions = @($partitions | ForEach-Object { @{ label=$_.Label; count=$_.Count; req_ids=$_.RequirementIds } })
        completed = @($completedJobs.Keys)
        failed = $failedPartitions
        timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    } | ConvertTo-Json -Compress -Depth 4
    Add-Content -Path $rotHistoryPath -Value $rotEntry -Encoding UTF8

    # Show coverage summary
    $coverageFile = Join-Path $GsdDir "code-review\coverage-matrix.json"
    Update-CoverageMatrix -GsdDir $GsdDir -Iteration $Iteration -Rotation $rotation `
        -CompletedLabels @($completedJobs.Keys) -PartitionReqIds @(
            $partitions | ForEach-Object { @{ Label=$_.Label; ReqIds=$_.RequirementIds } }
        )

    return $result
}


function Merge-PartitionedReviews {
    <#
    .SYNOPSIS
        Merges partition review outputs into unified health score and review files.
    #>
    param(
        [string]$GsdDir,
        [array]$Partitions,
        [array]$CompletedLabels,
        [array]$FailedLabels,
        [hashtable]$Rotation,
        [int]$Iteration
    )

    $result = @{ Health = 0; MergedReview = "" }

    # Re-read the requirements matrix (agents may have updated it)
    $matrixPath = Join-Path $GsdDir "health\requirements-matrix.json"
    if (Test-Path $matrixPath) {
        try {
            $matrix = Get-Content $matrixPath -Raw | ConvertFrom-Json
            $reqs = @($matrix.requirements)
            $total = $reqs.Count
            $satisfied = @($reqs | Where-Object { $_.status -eq "satisfied" }).Count
            $health = if ($total -gt 0) { [math]::Round(($satisfied / $total) * 100, 1) } else { 0 }

            # Update health
            $matrix.meta.health_score = $health
            $matrix.meta.satisfied = $satisfied
            $matrix.meta.iteration = $Iteration
            $matrix | ConvertTo-Json -Depth 10 | Set-Content $matrixPath -Encoding UTF8

            # Update health file
            $healthFile = Join-Path $GsdDir "health\health-current.json"
            @{
                health_score = $health
                total_requirements = $total
                satisfied = $satisfied
                partial = @($reqs | Where-Object { $_.status -eq "partial" }).Count
                not_started = @($reqs | Where-Object { $_.status -eq "not_started" }).Count
                iteration = $Iteration
            } | ConvertTo-Json | Set-Content $healthFile -Encoding UTF8

            # Append to health history
            $historyPath = Join-Path $GsdDir "health\health-history.jsonl"
            @{ iteration=$Iteration; health_score=$health; satisfied=$satisfied; total=$total; timestamp=(Get-Date -Format "o"); review_type="partitioned" } |
                ConvertTo-Json -Compress | Add-Content $historyPath -Encoding UTF8

            $result.Health = $health
        } catch {
            Write-Host "  [WARN] Failed to merge health: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    # Merge partition reviews into unified review-current.md
    $mergedLines = @("# Code Review - Iteration $Iteration (Partitioned)", "")
    $mergedLines += "| Partition | Agent | Status |"
    $mergedLines += "|-----------|-------|--------|"

    $labels = @("A", "B", "C")
    foreach ($label in $labels) {
        $agent = $Rotation[$label]
        $status = if ($CompletedLabels -contains $label) { "Completed" } else { "FAILED" }
        $mergedLines += "| $label | $agent | $status |"
    }
    $mergedLines += ""

    foreach ($label in $labels) {
        $partReviewPath = Join-Path $GsdDir "code-review\partition-$label-review.md"
        if (Test-Path $partReviewPath) {
            $content = (Get-Content $partReviewPath -Raw).Trim()
            $mergedLines += $content
            $mergedLines += ""
        }
    }

    # Merge drift reports
    $mergedDrift = @()
    foreach ($label in $labels) {
        $driftPath = Join-Path $GsdDir "code-review\partition-$label-drift.md"
        if (Test-Path $driftPath) {
            $content = (Get-Content $driftPath -Raw).Trim()
            if ($content.Length -gt 5) {
                $mergedDrift += "### Partition $label ($($Rotation[$label]))"
                $mergedDrift += $content
                $mergedDrift += ""
            }
        }
    }

    # Write merged files
    $reviewPath = Join-Path $GsdDir "code-review\review-current.md"
    ($mergedLines -join "`n") | Set-Content $reviewPath -Encoding UTF8

    $driftPath = Join-Path $GsdDir "health\drift-report.md"
    if ($mergedDrift.Count -gt 0) {
        ($mergedDrift -join "`n") | Set-Content $driftPath -Encoding UTF8
    }

    $result.MergedReview = $reviewPath
    return $result
}


function Update-CoverageMatrix {
    <#
    .SYNOPSIS
        Tracks which agent has reviewed which requirements across iterations.
        After 3 iterations, every requirement should be reviewed by all 3 agents.
    #>
    param(
        [string]$GsdDir,
        [int]$Iteration,
        [hashtable]$Rotation,
        [array]$CompletedLabels,
        [array]$PartitionReqIds
    )

    $coveragePath = Join-Path $GsdDir "code-review\coverage-matrix.json"
    $coverage = @{}

    if (Test-Path $coveragePath) {
        try { $coverage = Get-Content $coveragePath -Raw | ConvertFrom-Json -AsHashtable } catch { $coverage = @{} }
    }

    # Update coverage for completed partitions
    foreach ($pInfo in $PartitionReqIds) {
        $label = $pInfo.Label
        if ($CompletedLabels -notcontains $label) { continue }

        $agent = $Rotation[$label]
        foreach ($reqId in $pInfo.ReqIds) {
            if (-not $coverage.ContainsKey($reqId)) {
                $coverage[$reqId] = @{}
            }
            $coverage[$reqId][$agent] = $Iteration
        }
    }

    # Save and report
    $coverage | ConvertTo-Json -Depth 4 | Set-Content $coveragePath -Encoding UTF8

    # Count full-coverage requirements (reviewed by all 3 agents)
    $fullCoverage = 0
    $totalReqs = $coverage.Keys.Count
    foreach ($reqId in $coverage.Keys) {
        if ($coverage[$reqId].Keys.Count -ge 3) { $fullCoverage++ }
    }

    Write-Host "  [COVERAGE] $fullCoverage/$totalReqs requirements reviewed by all 3 agents" -ForegroundColor $(if ($fullCoverage -eq $totalReqs) { "Green" } else { "Yellow" })
}

Write-Host "  Partitioned code review modules loaded." -ForegroundColor DarkGray
'@

    if ($existing -match "GSD PARTITIONED CODE REVIEW MODULES") {
        $markerLine = "`n# GSD PARTITIONED CODE REVIEW MODULES"
        $idx = $existing.IndexOf($markerLine)
        if ($idx -gt 0) {
            $existing = $existing.Substring(0, $idx)
            Set-Content -Path $resilienceFile -Value $existing -Encoding UTF8
        }
        Add-Content -Path $resilienceFile -Value "`n$partitionCode" -Encoding UTF8
        Write-Host "  [OK] Updated partitioned code review modules in resilience.ps1" -ForegroundColor DarkGreen
    } else {
        Add-Content -Path $resilienceFile -Value "`n$partitionCode" -Encoding UTF8
        Write-Host "  [OK] Appended partitioned code review modules to resilience.ps1" -ForegroundColor DarkGreen
    }
}

# ── 4. Patch convergence pipeline to use partitioned code review ──

Write-Host "  [PATCH] Patching convergence pipeline..." -ForegroundColor Yellow

$convergenceScript = Join-Path $GsdGlobalDir "scripts\gsd-converge.ps1"
if (Test-Path $convergenceScript) {
    $convContent = Get-Content $convergenceScript -Raw

    if ($convContent -notlike "*Invoke-PartitionedCodeReview*") {
        # Find the code review section and wrap it with partitioned review logic
        $oldReviewBlock = @'
    # 1. CODE REVIEW (Claude)
    Send-HeartbeatIfDue -Phase "code-review" -Iteration $Iteration -Health $Health -RepoName $repoName
    Write-Host "  [SEARCH] CLAUDE -> code-review" -ForegroundColor Cyan
'@

        $newReviewBlock = @'
    # 1. CODE REVIEW (Partitioned: 3-agent parallel with rotation)
    Send-HeartbeatIfDue -Phase "code-review" -Iteration $Iteration -Health $Health -RepoName $repoName

    $usePartitionedReview = $false
    if (Get-Command Invoke-PartitionedCodeReview -ErrorAction SilentlyContinue) {
        $pcrConfigPath = Join-Path $GlobalDir "config\global-config.json"
        if (Test-Path $pcrConfigPath) {
            try {
                $pcrConfig = (Get-Content $pcrConfigPath -Raw | ConvertFrom-Json).partitioned_code_review
                if ($pcrConfig -and $pcrConfig.enabled) { $usePartitionedReview = $true }
            } catch {}
        }
    }

    if ($usePartitionedReview -and -not $DryRun) {
        Write-Host "  [PARTITION] 3-agent parallel code review (rotation enabled)" -ForegroundColor Cyan
        Save-Checkpoint -GsdDir $GsdDir -Pipeline "converge" -Iteration $Iteration -Phase "code-review-partitioned" -Health $Health -BatchSize $CurrentBatchSize
        if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
            Update-EngineStatus -GsdDir $GsdDir -State "running" -Phase "code-review-partitioned" -Agent "parallel" -Iteration $Iteration -HealthScore $Health -BatchSize $CurrentBatchSize
        }

        $pcrResult = Invoke-PartitionedCodeReview -RepoRoot $RepoRoot -GsdDir $GsdDir -GlobalDir $GlobalDir `
            -Iteration $Iteration -Health $Health -CurrentBatchSize $CurrentBatchSize `
            -InterfaceContext $InterfaceContext -DryRun:$DryRun

        if ($pcrResult.Success) {
            $Health = $pcrResult.Health
            if ($Health -ge $TargetHealth) { Write-Host "  [OK] CONVERGED!" -ForegroundColor Green; break }
        } else {
            # Fallback to single-agent Claude review
            Write-Host "  [PARTITION] Fallback to single-agent review: $($pcrResult.Error)" -ForegroundColor Yellow
            $usePartitionedReview = $false
        }
    }

    if (-not $usePartitionedReview) {
    Write-Host "  [SEARCH] CLAUDE -> code-review" -ForegroundColor Cyan
'@

        # Also need to close the if block after the single-agent review
        $oldPostReview = @'
    $Health = Get-Health
    if ($Health -ge $TargetHealth) { Write-Host "  [OK] CONVERGED!" -ForegroundColor Green; break }

    # Throttle between phases
'@
        $newPostReview = @'
    $Health = Get-Health
    if ($Health -ge $TargetHealth) { Write-Host "  [OK] CONVERGED!" -ForegroundColor Green; break }
    } # end single-agent fallback

    # Throttle between phases
'@

        if ($convContent -match [regex]::Escape($oldReviewBlock)) {
            $convContent = $convContent.Replace($oldReviewBlock, $newReviewBlock)
            $convContent = $convContent.Replace($oldPostReview, $newPostReview)
            Set-Content -Path $convergenceScript -Value $convContent -Encoding UTF8
            Write-Host "  [OK] Patched gsd-converge.ps1 with partitioned review" -ForegroundColor Green
        } else {
            Write-Host "  [SKIP] Could not find exact code review block to patch in gsd-converge.ps1" -ForegroundColor Yellow
            Write-Host "         The pipeline will use partitioned review via function availability check." -ForegroundColor DarkGray
        }
    } else {
        Write-Host "  [SKIP] gsd-converge.ps1 already has partitioned review" -ForegroundColor DarkGray
    }
} else {
    Write-Host "  [SKIP] gsd-converge.ps1 not found (will be created on first install)" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Green
Write-Host "  [OK] Partitioned Code Review Patch Applied" -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  HOW IT WORKS:" -ForegroundColor Yellow
Write-Host ""
Write-Host "  [PARTITION] Requirements split into 3 groups (A, B, C)" -ForegroundColor White
Write-Host "     - Even distribution with mixed statuses per partition" -ForegroundColor DarkGray
Write-Host "     - Each partition includes source files + spec + Figma refs" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  [ROTATION] Agent assignments rotate every iteration:" -ForegroundColor White
Write-Host "     Iter 1: A=Claude  B=Gemini  C=Codex" -ForegroundColor DarkGray
Write-Host "     Iter 2: A=Gemini  B=Codex   C=Claude" -ForegroundColor DarkGray
Write-Host "     Iter 3: A=Codex   B=Claude  C=Gemini" -ForegroundColor DarkGray
Write-Host "     (repeats every 3 iterations)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  [PARALLEL] All 3 agents run simultaneously" -ForegroundColor White
Write-Host "     - 3x faster than sequential single-agent review" -ForegroundColor DarkGray
Write-Host "     - Each agent validates against spec AND Figma deliverables" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  [COVERAGE] After 3 iterations, every requirement reviewed by all 3 LLMs" -ForegroundColor White
Write-Host "     - Coverage matrix tracked in .gsd/code-review/coverage-matrix.json" -ForegroundColor DarkGray
Write-Host "     - Rotation history in .gsd/code-review/rotation-history.jsonl" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  PARTITION FOCUS AREAS:" -ForegroundColor Yellow
Write-Host "     A: Implementation & Architecture (DI, patterns, contracts)" -ForegroundColor DarkGray
Write-Host "     B: Data Flow & Integration (E2E chains, wiring, seed data)" -ForegroundColor DarkGray
Write-Host "     C: Security, Compliance & UX (OWASP, HIPAA, Figma match)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  CONFIG: global-config.json -> partitioned_code_review" -ForegroundColor Yellow
Write-Host "  DISABLE: set partitioned_code_review.enabled = false" -ForegroundColor DarkGray
Write-Host "  FALLBACK: auto-falls back to single Claude review if < 3 requirements" -ForegroundColor DarkGray
Write-Host ""
